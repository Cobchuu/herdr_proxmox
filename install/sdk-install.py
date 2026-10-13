#!/usr/bin/python3
"""Root-only SDK installer. Accepts no arguments and no installer options.

Like the dashboard updater, this worker never executes anything from a request.
The only accepted request is a bare install action naming a toolchain, and that
name is resolved through the catalog the release itself ships: the script it
selects is release content under /opt/herdr-web, so the request still cannot
influence any command, path or version that runs. Installer output is retained
as a bounded tail so a failed run is diagnosable from the dashboard.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import stat

RELEASE = Path('/opt/herdr-web')
STATE = Path('/var/lib/herdr-sdk')
REQUEST = Path('/var/lib/herdr-sdk-requests/request.json')
CATALOG = RELEASE / 'install/toolchains.json'
OUTPUT_LIMIT = 1800
TIMEOUT_SECONDS = 1800
VERSION = re.compile(r'\d+(?:\.\d+)+')


def parse_request(text):
    """Accept a bare install action, optionally naming one catalogued toolchain."""
    payload = json.loads(text)
    if not isinstance(payload, dict) or payload.get('action') != 'install':
        raise ValueError('Unsupported SDK install request.')
    if set(payload) - {'action', 'toolchain'}:
        raise ValueError('SDK installation does not accept options.')
    if 'toolchain' in payload and (not isinstance(payload['toolchain'], str) or not payload['toolchain']):
        raise ValueError('Unsupported SDK install request.')
    return payload


def load_catalog(path=None):
    """Read the release's toolchain catalog. An unreadable catalog installs nothing."""
    try:
        catalog = json.loads((CATALOG if path is None else path).read_text())
    except (OSError, ValueError):
        raise ValueError('This dashboard release does not include a readable SDK catalog.')
    if not isinstance(catalog, dict) or not catalog:
        raise ValueError('This dashboard release does not include a readable SDK catalog.')
    return catalog


def resolve(name, catalog, release=None):
    """Map a requested toolchain to an installer inside the release, or refuse."""
    release = RELEASE if release is None else release
    if not isinstance(name, str) or name not in catalog:
        raise ValueError('This release does not provision that toolchain.')
    entry = catalog[name]
    if not isinstance(entry, dict):
        raise ValueError('This release does not provision that toolchain.')
    value = entry.get('script')
    if (not isinstance(value, str) or not value or '\\' in value
            or PurePosixPath(value).is_absolute() or Path(value).is_absolute()
            or '..' in PurePosixPath(value).parts):
        raise ValueError('This release does not provision that toolchain.')
    script = release / value
    # Checked before resolving, which would follow the link and hide it. The
    # catalog is release content, but the resolved path is still confined to the
    # release: a traversal or an absolute escape would otherwise turn the name
    # into arbitrary root execution.
    if any((release / Path(*Path(value).parts[:index])).is_symlink()
           for index in range(1, len(Path(value).parts) + 1)):
        raise ValueError('This release does not provision that toolchain.')
    try:
        script = script.resolve(strict=True)
        script.relative_to(release.resolve(strict=True))
    except (OSError, ValueError):
        raise ValueError('This release does not provision that toolchain.')
    if not script.is_file():
        raise ValueError('This release does not provision that toolchain.')
    return script


def status(state, **fields):
    temporary = STATE / 'status.tmp'
    temporary.write_text(json.dumps(dict(state=state, **fields)))
    temporary.chmod(0o644)
    temporary.replace(STATE / 'status.json')


def declared_version(entry, release=None):
    """Read the required version from the repository's own declaration.

    Deliberately not imported from the release's Python: this worker is installed
    standalone under /usr/local/sbin and must not load code from the tree it
    installs. It reads only the declaration file, and a request cannot influence
    the value.
    """
    release = RELEASE if release is None else release
    source = entry.get('version_source')
    if not isinstance(source, dict):
        return None
    try:
        text = (release / str(source.get('file', ''))).read_text()
        value = json.loads(text).get(source.get('key')) if source.get('key') else text.strip()
    except (OSError, ValueError, AttributeError):
        return None
    return value if isinstance(value, str) and VERSION.fullmatch(value) else None


def probe(entry, version):
    """Report what the installed SDK actually is, rather than what was requested."""
    executable = entry.get('executable')
    if not isinstance(executable, str):
        return None
    path = Path(executable.replace('{version}', str(version)))
    if not path.is_file():
        return None
    try:
        # SDK files belong to herdr and may have been changed by a session.
        # Never execute those files as the root installation worker.
        result = subprocess.run(['runuser', '-u', 'herdr', '--', 'env', '-i',
                                 'HOME=/home/herdr', 'USER=herdr', 'LOGNAME=herdr',
                                 'PATH=/usr/local/bin:/usr/bin:/bin',
                                 str(path), '--version', '--machine'], capture_output=True,
                                text=True, timeout=300)
        reported = json.loads(result.stdout or '{}').get('frameworkVersion') if result.returncode == 0 else None
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        return None
    return reported if isinstance(reported, str) and reported else None


def install(script):
    result = subprocess.run(['bash', str(script)], capture_output=True, text=True,
                            timeout=TIMEOUT_SECONDS,
                            env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'})
    # Keep stderr even when apt/curl produced stdout; it usually contains
    # the actual installer failure, and the status message retains the final tail.
    tail = ((result.stdout or '') + '\n' + (result.stderr or '')).strip()[-OUTPUT_LIMIT:]
    if result.returncode:
        raise ValueError('SDK installation failed. Inspect journalctl -u herdr-sdk. ' + tail)
    return tail


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root through herdr-sdk.service.')
    STATE.mkdir(exist_ok=True)
    try:
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        if REQUEST.is_symlink():
            raise ValueError('Invalid SDK install request.')
        with os.fdopen(os.open(REQUEST, flags), 'r') as request:
            metadata = os.fstat(request.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1024:
                raise ValueError('Invalid SDK install request.')
            parsed = parse_request(request.read(1025))
        REQUEST.unlink()
        catalog = load_catalog()
        name = parsed.get('toolchain')
        # An older gateway sends a bare action with no name. That is only
        # unambiguous while the release provisions exactly one toolchain, so the
        # request cannot silently pick one of several.
        if 'toolchain' not in parsed and len(catalog) == 1:
            name = next(iter(catalog))
        if not name:
            raise ValueError('Unsupported SDK install request.')
        script = resolve(name, catalog)
        entry = catalog[name]
        version = declared_version(entry)
        if not version:
            raise ValueError('This release declares no version for that toolchain.')
        status('running', started_at=datetime.now(timezone.utc).isoformat(),
               toolchain=name, required=version)
        tail = install(script)
        # The installed SDK is probed rather than assumed: the whole point is
        # that an installation can differ from what was requested.
        reported = probe(entry, version)
        if reported != version:
            raise ValueError(f'Required {name} {version}; the installed SDK reports '
                             f'{reported or "no version"}. Inspect journalctl -u herdr-sdk. ' + tail)
        status('complete', output=tail, toolchain=name, required=version, reported=reported)
    except Exception as exc:
        REQUEST.unlink(missing_ok=True)
        status('failed', error=str(exc)[:2000])
        raise


if __name__ == '__main__':
    main()
