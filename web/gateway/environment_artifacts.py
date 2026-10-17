"""Trusted SDK distribution providers and unprivileged, verified acquisition.

Repository data chooses a requirement, never a URL, extraction directory or
installer command. Provider metadata supplies immutable artifact hashes. Network
access occurs only during explicit preparation, never during analysis reads.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import uuid
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+')
PROVIDER_VERSION = 1
METADATA_LIMIT = 16 * 1024 * 1024
DOWNLOAD_LIMIT = 1024 * 1024 * 1024
EXTRACT_LIMIT = 4 * DOWNLOAD_LIMIT
FILE_LIMIT = 100_000
HOSTS = frozenset(('dotnetcli.blob.core.windows.net', 'builds.dotnet.microsoft.com',
                  'ci.dot.net', 'download.visualstudio.microsoft.com', 'static.rust-lang.org'))
METADATA = {'dotnet-sdk': 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/',
            'rust-toolchain': 'https://static.rust-lang.org/dist/'}


def trusted_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or parsed.hostname not in HOSTS or parsed.port not in (None, 443)
            or parsed.username or parsed.password or parsed.fragment):
        raise ValueError('SDK provider returned an untrusted download location.')
    return value


class TrustedRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, url):
        return super().redirect_request(request, stream, code, message, headers, trusted_url(url))


def download(url, destination, limit=DOWNLOAD_LIMIT, cancelled=lambda: False):
    """Stream bounded data; credentials, redirects and cancellation stay scoped."""
    opener = build_opener(TrustedRedirect())
    request = Request(trusted_url(url), headers={'User-Agent': 'Herdr-environments/1'})
    size, deadline = 0, time.monotonic() + 900
    with closing(opener.open(request, timeout=30)) as source, open(destination, 'wb') as output:
        while True:
            if cancelled() or time.monotonic() > deadline:
                raise ValueError('SDK acquisition was cancelled or exceeded its deadline.')
            chunk = source.read(128 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > limit:
                raise ValueError('SDK provider response exceeds its byte budget.')
            output.write(chunk)


def metadata(url, fetch=download):
    with tempfile.TemporaryDirectory(prefix='herdr-sdk-metadata-') as folder:
        path = Path(folder) / 'metadata'
        fetch(trusted_url(url), path, limit=METADATA_LIMIT)
        return path.read_bytes()


def host_target():
    """Initial acquisition support is explicit: Linux glibc x64/arm64."""
    machine = platform.machine().lower()
    architecture = {'x86_64': 'x64', 'amd64': 'x64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(machine)
    if not sys.platform.startswith('linux') or not architecture or platform.libc_ver()[0] != 'glibc':
        raise ValueError('Managed SDK acquisition currently requires Linux glibc x64 or arm64.')
    return dict(os='linux', architecture=architecture, libc='glibc')


def artifact(url, value, algorithm, **fields):
    if not isinstance(value, str) or not re.fullmatch(
            '[0-9a-fA-F]{' + str(hashlib.new(algorithm).digest_size * 2) + '}', value):
        raise ValueError('SDK distribution metadata has no valid artifact digest.')
    return dict(url=trusted_url(url), hash=value.lower(), algorithm=algorithm, **fields)


def resolve(capability, version, target=None, read=metadata):
    """Resolve an exact SDK through publisher metadata, not a release-wide pin."""
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError('Acquisition requires a resolved three-part SDK version.')
    target = host_target() if target is None else target
    if target not in (dict(os='linux', architecture='x64', libc='glibc'),
                       dict(os='linux', architecture='arm64', libc='glibc')):
        raise ValueError('The SDK provider does not support this executor.')
    if capability == 'dotnet-sdk':
        url = METADATA[capability] + '.'.join(version.split('.')[:2]) + '/releases.json'
        data = json.loads(read(url))
        candidates = []
        for release in data.get('releases', []):
            candidates.extend(release.get('sdks', []))
            if isinstance(release.get('sdk'), dict):
                candidates.append(release['sdk'])
        rid = 'linux-' + target['architecture']
        files = [item for sdk in candidates if sdk.get('version') == version
                 for item in sdk.get('files', [])
                 if item.get('rid') == rid and str(item.get('url', '')).endswith('.tar.gz')]
        if not files:
            raise ValueError(f'The publisher has no .NET SDK {version} artifact for {rid}.')
        item = files[0]
        archives = [artifact(item['url'], item.get('hash'), 'sha512', component='sdk')]
    elif capability == 'rust-toolchain':
        url = METADATA[capability] + 'channel-rust-' + version + '.toml'
        data = tomllib.loads(read(url).decode('utf-8'))
        triple = ('x86_64' if target['architecture'] == 'x64' else 'aarch64') + '-unknown-linux-gnu'
        archives = []
        for package in ('rustc', 'cargo', 'rust-std'):
            item = data.get('pkg', {}).get(package, {}).get('target', {}).get(triple, {})
            if not item.get('available'):
                raise ValueError(f'Rust {version} has no {package} artifact for {triple}.')
            archives.append(artifact(item.get('xz_url', ''), item.get('xz_hash'), 'sha256', component=package))
    else:
        raise ValueError(f'No trusted artifact provider exists for {capability}.')
    return dict(provider_version=PROVIDER_VERSION, capability=capability,
                version=version, target=target, metadata=url, archives=archives)


def identity(specification):
    return hashlib.sha256(json.dumps(specification, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def unpack(archive, destination, limit=EXTRACT_LIMIT):
    """Archives publish only ordinary files/directories inside a new private tree."""
    total = 0
    with tarfile.open(archive, 'r:*') as source:
        for count, member in enumerate(source, 1):
            name = PurePosixPath(member.name)
            if (count > FILE_LIMIT or name.is_absolute() or '..' in name.parts
                    or '\\' in member.name or ':' in member.name
                    or not (member.isfile() or member.isdir())):
                raise ValueError('SDK archive contains an unsupported or unsafe entry.')
            total += member.size
            if total > limit:
                raise ValueError('SDK archive exceeds its extraction budget.')
            path = destination.joinpath(*name.parts)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with closing(source.extractfile(member)) as data, path.open('xb') as output:
                shutil.copyfileobj(data, output, 128 * 1024)
            path.chmod(0o755 if member.mode & 0o111 else 0o644)
    return total


def probe(capability, root, run=subprocess.run):
    executable = root / ('dotnet' if capability == 'dotnet-sdk' else 'bin/rustc')
    arguments = ['--list-sdks'] if capability == 'dotnet-sdk' else ['-Vv']
    environment = dict(os.environ, DOTNET_ROOT=str(root), DOTNET_MULTILEVEL_LOOKUP='0')
    result = run([str(executable), *arguments], cwd=root, env=environment,
                 capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError('The installed SDK probe failed; inspect native host dependencies. '
                         + (result.stderr or '')[-600:])
    output = result.stdout[:16_000]
    versions = re.findall(r'^([0-9]+\.[0-9]+\.[0-9]+)\s+\[', output, re.MULTILINE) if capability == 'dotnet-sdk' else re.findall(
        r'^release: ([0-9]+\.[0-9]+\.[0-9]+)$', output, re.MULTILINE)
    if not versions:
        raise ValueError('The installed SDK did not report an identifiable version.')
    measured = dict(executable=str(executable), versions=versions, output=output)
    if capability == 'rust-toolchain':
        cargo = run([str(root / 'bin/cargo'), '--version'], cwd=root, env=environment,
                    capture_output=True, text=True, timeout=30)
        cargo_version = re.match(r'cargo ([0-9]+\.[0-9]+\.[0-9]+)\b', cargo.stdout)
        if cargo.returncode or not cargo_version:
            raise ValueError('The installed Cargo probe failed; the Rust SDK is incomplete.')
        # Cargo and rustc patch versions need not match. Both must be usable,
        # and their downloaded artifacts already have distinct publisher hashes.
        measured['cargo_version'] = cargo_version[1]
    return measured


def acquire(specification, store, fetch=download, verify=probe, cancelled=lambda: False):
    """Stage, hash, unpack and probe; publish atomically only after verification."""
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        raise ValueError('Managed SDK acquisition must run as an unprivileged service user.')
    key = identity(specification)
    store = Path(store)
    store.mkdir(parents=True, exist_ok=True, mode=0o700)
    if store.is_symlink():
        raise ValueError('The managed SDK store must not be a symlink.')
    final = store / key
    if final.is_symlink():
        raise ValueError('The managed SDK installation must not be a symlink.')
    receipt_path = final / 'herdr-receipt.json'
    if final.exists():
        try:
            receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
        except FileNotFoundError:
            # Preserve the unverified tree for inspection, then acquire afresh.
            # Never certify existing bytes merely because their directory exists.
            quarantine = store / ('.unverified-' + key + '-' + uuid.uuid4().hex)
            if final.resolve().parent != store.resolve() or quarantine.resolve().parent != store.resolve():
                raise ValueError('The unverified SDK lies outside the managed store.')
            final.rename(quarantine)
        except (OSError, ValueError) as error:
            raise ValueError('The existing SDK receipt could not be read; inspect the managed installation.') from error
        else:
            if not isinstance(receipt, dict) or receipt.get('artifact_id') != key or receipt.get('specification') != specification:
                raise ValueError('The existing SDK has an incompatible receipt.')
            measured = verify(specification['capability'], final)
            if specification['version'] not in measured['versions']:
                raise ValueError('The existing SDK no longer matches its receipt.')
            return dict(receipt, probe=measured)
    with tempfile.TemporaryDirectory(prefix='.acquiring-', dir=store) as folder:
        stage = Path(folder)
        prefix = stage / 'sdk'
        prefix.mkdir()
        unpacked_bytes = 0
        for index, entry in enumerate(specification['archives']):
            if cancelled():
                raise ValueError('SDK acquisition was cancelled.')
            archive = stage / f'{index}.tar'
            if entry['algorithm'] not in ('sha256', 'sha512'):
                raise ValueError('SDK archives require SHA-256 or SHA-512 verification.')
            fetch(trusted_url(entry['url']), archive, cancelled=cancelled)
            digest = hashlib.new(entry['algorithm'])
            with archive.open('rb') as source:
                for chunk in iter(lambda: source.read(128 * 1024), b''):
                    digest.update(chunk)
            if digest.hexdigest() != entry['hash']:
                raise ValueError('SDK archive failed its publisher digest check.')
            if specification['capability'] == 'dotnet-sdk':
                unpacked_bytes += unpack(archive, prefix, EXTRACT_LIMIT - unpacked_bytes)
            else:
                extracted = stage / f'unpacked-{index}'
                extracted.mkdir()
                unpacked_bytes += unpack(archive, extracted, EXTRACT_LIMIT - unpacked_bytes)
                roots = list(extracted.iterdir())
                if len(roots) != 1 or not roots[0].is_dir():
                    raise ValueError('Rust distribution has an unsupported archive layout.')
                components = (roots[0] / 'components').read_text(encoding='utf-8').splitlines()
                for component in components:
                    if not re.fullmatch(r'[A-Za-z0-9_-]+', component):
                        raise ValueError('Rust distribution names an invalid component.')
                    shutil.copytree(roots[0] / component, prefix, dirs_exist_ok=True,
                                    ignore=shutil.ignore_patterns('manifest.in'))
        measured = verify(specification['capability'], prefix)
        if specification['version'] not in measured['versions']:
            raise ValueError('The acquired SDK does not report the requested version.')
        measured = dict(measured, executable=str(final / Path(measured['executable']).relative_to(prefix)))
        receipt = dict(artifact_id=key, specification=specification, probe=measured)
        (prefix / 'herdr-receipt.json').write_text(json.dumps(receipt, sort_keys=True), encoding='utf-8')
        if cancelled():
            raise ValueError('SDK acquisition was cancelled before publication.')
        prefix.rename(final)
    # Staging paths never escape into the persisted executable binding.
    return dict(receipt, probe=verify(specification['capability'], final))
