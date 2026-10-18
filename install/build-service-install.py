#!/usr/bin/python3
"""Root worker for a fixed, option-free build-service installation request."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import subprocess

RELEASE = Path('/opt/herdr-web')
REQUEST = Path('/var/lib/herdr-build-install-requests/request.json')
STATE = Path('/var/lib/herdr-build-install')
SCRIPT = RELEASE / 'install/build-install.sh'
DEADLINE_SECONDS = 660  # Keep in sync with the gateway; this worker imports no release code.


def parse_request(text):
    payload = json.loads(text)
    if payload != {'action': 'install'}:
        raise ValueError('Build-service installation accepts only a bare install action.')
    return payload


def status(value, **fields):
    temporary = STATE / 'status.tmp'
    temporary.write_text(json.dumps(dict(state=value, **fields)), encoding='utf-8')
    temporary.chmod(0o644)
    temporary.replace(STATE / 'status.json')


def release_script_is_trusted():
    """Whether the release installer is content this worker may run as root.

    Fixed release content only; the request supplies no paths, arguments,
    environment, units or commands for the root process. The script is executed
    as root, so it must live inside the release and be root-owned and not
    writable by anyone else — a symlink, a link swap or a group/other write bit
    would turn a release file into arbitrary root execution.
    """
    try:
        release = RELEASE.resolve(strict=True)
        script = SCRIPT.resolve(strict=True)
        script.relative_to(release)
        metadata = script.stat()
    except (OSError, ValueError):
        return False
    if not stat.S_ISREG(metadata.st_mode):
        return False
    # Ownership and permission bits are POSIX facts. This worker only runs under
    # systemd inside the container, but the suite also exercises it on Windows,
    # where neither field carries a meaning.
    return os.name != 'posix' or (metadata.st_uid == 0 and not metadata.st_mode & 0o022)


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root through herdr-build-install.service.')
    STATE.mkdir(exist_ok=True)
    claimed = STATE / 'request.json'
    try:
        # Publish activity before atomically claiming the request. Cleanup owns
        # only this claimed file, never a newer retry queued by the gateway.
        status('running', started_at=datetime.now(timezone.utc).isoformat())
        REQUEST.replace(claimed)
        flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        if claimed.is_symlink():
            raise ValueError('Invalid build-service installation request.')
        with os.fdopen(os.open(claimed, flags), 'r') as request:
            metadata = os.fstat(request.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1024:
                raise ValueError('Invalid build-service installation request.')
            parse_request(request.read(1025))
        if not release_script_is_trusted():
            raise ValueError('The release build-service installer is missing or unsafe.')
        if datetime.now(timezone.utc).timestamp() - metadata.st_mtime > DEADLINE_SECONDS:
            raise ValueError('Build-service installation request expired before the worker started. Request installation again.')
        result = subprocess.run(['/bin/bash', str(SCRIPT)], capture_output=True, text=True, timeout=600,
                                env={'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                                     'HOME': '/root', 'LANG': 'C.UTF-8'})
        output = ((result.stdout or '') + '\n' + (result.stderr or '')).strip()[-1800:]
        if result.returncode:
            raise ValueError('Build-service installation failed. ' + output)
        status('complete', output=output)
    except Exception as error:
        status('failed', error=str(error)[:2000])
        raise
    finally:
        claimed.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
