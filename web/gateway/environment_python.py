"""Pinned CPython selection and acquisition, separate from execution environments.

The release vendors uv's stable Linux catalog. A range selects the highest
compatible stable version in that catalog, never a moving upstream 'latest'.
Herdr verifies the uv and PBS archive hashes itself; those are distribution
checksums, not signatures or publisher attestations. uv performs installation
fixups at the final path. Neither the gateway interpreter nor user defaults move.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit
import uuid

import dependency_constraints

CATALOG = Path(__file__).resolve().parents[2] / 'install/python-tools.json'
PROBE = ('import json,sys,ssl,sqlite3,venv; '
         'print(json.dumps(dict(version=".".join(map(str,sys.version_info[:3])), '
         'implementation=sys.implementation.name, prefix=sys.prefix, base_prefix=sys.base_prefix, '
         'executable=sys.executable, ssl=ssl.OPENSSL_VERSION, sqlite=sqlite3.sqlite_version)))')


def catalog():
    """Read release-owned metadata; source_sha256 is upstream provenance.

    It describes the original upstream catalog, not a runtime hash check of this
    filtered copy. Downloads and installed interpreter bytes are checked separately.
    """
    return json.loads(CATALOG.read_text(encoding='utf-8'))


def select(declarations, target, data=None):
    """Pure selection: all constraints must be decidably satisfied; no probes."""
    data = catalog() if data is None else data
    architecture = {'x64': 'x86_64', 'arm64': 'aarch64'}.get(target.get('architecture'))
    if target.get('os') != 'linux' or target.get('libc') != 'glibc' or not architecture:
        raise ValueError('Python preparation requires Linux glibc x64 or arm64.')
    if not declarations:
        raise ValueError('Declare a Python constraint before automatic selection.')
    found = []
    for key, item in data['interpreters'].items():
        if (item['arch']['family'] != architecture or item.get('variant') or item.get('prerelease')
                or item['name'] != 'cpython' or item['os'] != 'linux' or item['libc'] != 'gnu'):
            continue
        version = '.'.join(str(item[part]) for part in ('major', 'minor', 'patch'))
        if all(dependency_constraints.evaluate(value, version, notation) == 'satisfied'
               for value, notation in declarations):
            found.append((tuple(map(int, version.split('.'))), key, item))
    if not found:
        raise ValueError('No stable CPython in the pinned catalog satisfies every declaration.')
    _, key, item = max(found)
    return dict(provider='pinned_uv', provider_version=1, capability='python',
        version='.'.join(str(item[part]) for part in ('major', 'minor', 'patch')),
        target=target, selection_policy=data['selection_policy'], catalog_sha256=data['source_sha256'],
        uv_version=data['uv_version'], uv_archive=data['uv_archives'][target['architecture']],
        installation_key=key, distribution=item)


def resolve_requirement(item, target):
    """The only provider entry point: keep every original declaration/notation."""
    import project_requirements
    if item['conflicts'] and not item.get('override'):
        raise ValueError('Resolve conflicting Python declarations before preparation.')
    declarations = [declaration for entry in ([item['override']] if item.get('override') else item['evidence'])
                    for declaration in project_requirements.declarations(entry, item['notation'])]
    return select(declarations, target)


def plan_requirement(item, *, paths, read, revision, resolve, specifications):
    import environment_artifacts
    import environment_providers
    import environment_python_execution
    specification = environment_providers.resolve_requirement(item, environment_artifacts.host_target())
    recipes = [environment_python_execution.recipe(component, paths, read, specification, revision)
               for component in item['components']]
    item.update(state='acquire', version=specification['version'], artifact=specification,
        activation='available', activation_reason='', restore_recipes=recipes,
        reason='Selected the highest stable compatible CPython in the pinned uv catalog.')


def acquire_provider(specification, store, *, fetch, verify=None, cancelled=lambda: False):
    # Installer strategies own their functionality probe; the archive-only
    # injection cannot replace it with a weaker generic --version check.
    if verify is not None:
        raise ValueError('The pinned uv provider requires its own functionality verification.')
    return acquire(specification, store, fetch=fetch, cancelled=cancelled)


def verify_entry(entry):
    receipt = entry.get('artifact_receipt')
    if not receipt:
        raise ValueError('The prepared interpreter receipt is missing; prepare again.')
    verify(receipt['specification'], receipt)


def clean_environment(home):
    """No inherited manager, interpreter, virtualenv or pip configuration."""
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('UV_', 'PYTHON', 'PIP_', 'POETRY_', 'CONDA_'))
           and key not in ('VIRTUAL_ENV', '__PYVENV_LAUNCHER__')}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'),
        XDG_CACHE_HOME=str(home / 'cache'), UV_NO_CONFIG='1', UV_PYTHON_INSTALL_BIN='false',
        UV_PYTHON_INSTALL_REGISTRY='false', UV_PYTHON_NO_REGISTRY='1', UV_NO_ENV_FILE='1', PYTHONDONTWRITEBYTECODE='1',
        PIP_CONFIG_FILE=os.devnull, PIP_DISABLE_PIP_VERSION_CHECK='1')
    return env


def probe(executable, cwd, run=subprocess.run):
    result = run([str(executable), '-I', '-B', '-c', PROBE], cwd=cwd,
        env=clean_environment(Path(cwd)), capture_output=True, text=True, timeout=30)
    if result.returncode or len(result.stdout) > 16000:
        raise ValueError('Python functionality probe failed (ssl, sqlite3 and venv are required).')
    measured = json.loads(result.stdout)
    if measured.get('implementation') != 'cpython' or not re.fullmatch(r'3\.\d+\.\d+', measured.get('version', '')):
        raise ValueError('Python did not report a supported CPython runtime.')
    return dict(executable=str(executable), versions=[measured['version']], functionality=measured)


def normalize_installation_links(root):
    """Keep uv's absolute internal aliases within the relative-only SDK contract.

    Run only on a newly acquired private installation, before its receipt is
    written. Verification never repairs a changed installation.
    """
    root = Path(root).resolve(strict=True)
    replacements = []
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in sorted([*directories, *files]):
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            target = path.resolve(strict=True)
            if not target.is_relative_to(root):
                raise ValueError(f'Python installation contains an external symbolic link: {path.relative_to(root)}.')
            if Path(os.readlink(path)).is_absolute():
                replacements.append((path, os.path.relpath(target, path.parent)))
    # Validate every link before making any changes.
    for path, target in replacements:
        path.unlink()
        path.symlink_to(target)


def fingerprint(root):
    """Internal relative links are SDK layout; virtual environments never enter here.

    Do not follow links while walking. Linked ancestors in regular-file reads
    are refused by the same anchored descriptor boundary as project discovery.
    """
    from project_access import open_project
    root = Path(root)
    digest, total, count = hashlib.sha256(), 0, 0
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Python installation must be a real directory.')
    for directory, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        for name in sorted([*directories, *files]):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            count += 1
            if count > 100000:
                raise ValueError('Python installation exceeds its file budget.')
            if path.is_symlink():
                target = os.readlink(path)
                if Path(target).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError(f'Python installation contains an external symbolic link: {relative}.')
                value = ['link', relative, target]
            elif path.is_dir():
                value = ['directory', relative]
            else:
                import stat
                with open_project(root, relative) as fd:
                    info = os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode):
                        raise ValueError('Python installation contains a special file.')
                    total += info.st_size
                    if total > 4 * 1024**3:
                        raise ValueError('Python installation exceeds its byte budget.')
                    content = hashlib.sha256()
                    with os.fdopen(os.dup(fd), 'rb') as stream:
                        for chunk in iter(lambda: stream.read(131072), b''):
                            content.update(chunk)
                value = ['file', relative, info.st_mode & 0o777, content.hexdigest()]
            digest.update((json.dumps(value, separators=(',', ':')) + '\n').encode())
    return digest.hexdigest()


def acquire(specification, store, fetch=None, cancelled=lambda: False, run=subprocess.run):
    """Serialize final-location fixups across preparation workers/processes."""
    import environment_artifacts as artifacts
    import fcntl
    import stat
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        raise ValueError('Python acquisition must run as an unprivileged service user.')
    root = Path(store).absolute()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink():
        raise ValueError('The Python store must not be a symlink.')
    descriptor = os.open(root / ('.python-' + artifacts.identity(specification) + '.lock'),
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'r+b') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError('The Python acquisition lock must be a regular file.')
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError('Python acquisition is already running; retry after it completes.') from error
        return _acquire(specification, root, fetch, cancelled, run)


def _acquire(specification, store, fetch=None, cancelled=lambda: False, run=subprocess.run):
    """Hash both downloads, then let pinned uv install from a local-only mirror."""
    import environment_artifacts as artifacts
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        raise ValueError('Python acquisition must run as an unprivileged service user.')
    fetch = fetch or artifacts.download
    root = Path(store).absolute()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = artifacts.identity(specification)
    final = root / key
    if root.is_symlink() or final.is_symlink():
        raise ValueError('Python installations must not be symlinks.')
    receipt_path = final / 'herdr-receipt.json'
    if final.exists():
        if receipt_path.exists():
            receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
            verify(specification, receipt)
            return dict(receipt, probe=probe(receipt['probe']['executable'], final, run=run))
        final.rename(root / ('.unverified-' + key + '-' + uuid.uuid4().hex))
    # mkdir is the cross-process admission fence. Do not relocate this directory
    # after uv's fixups, even on failure; the next attempt quarantines it.
    final.mkdir(mode=0o700)
    with tempfile.TemporaryDirectory(prefix='.python-download-', dir=root) as temporary:
        stage = Path(temporary)
        uv = specification['uv_archive']
        distribution = specification['distribution']
        if not uv['url'].startswith('https://github.com/astral-sh/uv/releases/download/') or not distribution['url'].startswith(
                'https://github.com/astral-sh/python-build-standalone/releases/download/'):
            raise ValueError('Python acquisition sources must be pinned Astral distributions.')
        for name, entry in (('uv.tar.gz', uv), ('python.tar.gz', distribution)):
            if cancelled():
                raise ValueError('Python acquisition was cancelled.')
            fetch(entry['url'], stage / name, cancelled=cancelled)
            with (stage / name).open('rb') as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            if actual != entry['sha256']:
                raise ValueError('Python preparation archive failed its distribution checksum.')
        artifacts.unpack(stage / 'uv.tar.gz', final / 'tool')
        tools = list((final / 'tool').glob('*/uv'))
        if len(tools) != 1:
            raise ValueError('Pinned uv archive has an unsupported layout.')
        uv_path = tools[0]
        env = clean_environment(stage)
        result = run([str(uv_path), '--version'], cwd=stage, env=env, capture_output=True, text=True, timeout=30)
        if result.returncode or not result.stdout.startswith('uv ' + specification['uv_version'] + ' '):
            raise ValueError('The preparation tool did not report its pinned uv version.')
        suffix = unquote(urlsplit(distribution['url']).path.split('/releases/download/', 1)[1])
        mirror = stage / 'mirror'
        archive = mirror / suffix
        archive.parent.mkdir(parents=True)
        (stage / 'python.tar.gz').rename(archive)
        metadata = stage / 'downloads.json'
        metadata.write_text(json.dumps({specification['installation_key']: distribution}), encoding='utf-8')
        env.update(UV_PYTHON_INSTALL_DIR=str(final / 'interpreters'),
                   UV_PYTHON_INSTALL_MIRROR=mirror.as_uri(), UV_PYTHON_DOWNLOADS_JSON_URL=str(metadata))
        result = run([str(uv_path), '--no-config', 'python', 'install', specification['installation_key']],
            cwd=stage, env=env, capture_output=True, text=True, timeout=300)
        if result.returncode or cancelled():
            raise ValueError('Pinned uv Python installation failed or was cancelled: ' + (result.stderr or '')[-600:])
    normalize_installation_links(final / 'interpreters')
    executable = final / 'interpreters' / specification['installation_key'] / 'bin/python3'
    measured = probe(executable, final, run=run)
    if measured['versions'] != [specification['version']]:
        raise ValueError('Installed Python differs from the frozen selection.')
    receipt = dict(artifact_id=key, specification=specification, probe=measured,
        uv_executable=str(uv_path), tree_digest=fingerprint(final / 'interpreters'),
        uv_sha256=hashlib.sha256(uv_path.read_bytes()).hexdigest(),
        integrity='distribution_checksums_and_local_fingerprint')
    receipt_path.write_text(json.dumps(receipt, sort_keys=True), encoding='utf-8')
    return receipt


def verify(specification, receipt):
    import environment_artifacts as artifacts
    if receipt.get('specification') != specification or receipt.get('artifact_id') != artifacts.identity(specification):
        raise ValueError('The Python receipt does not identify its frozen artifact.')
    executable = Path(receipt['probe']['executable'])
    root = executable.parents[3]
    if (root.name != artifacts.identity(specification)
            or executable != root / 'interpreters' / specification['installation_key'] / 'bin/python3'
            or not Path(receipt['uv_executable']).is_relative_to(root / 'tool')
            or fingerprint(root / 'interpreters') != receipt.get('tree_digest')
            or hashlib.sha256(Path(receipt['uv_executable']).read_bytes()).hexdigest() != receipt.get('uv_sha256')):
        raise ValueError('The prepared Python installation failed its content integrity check.')
