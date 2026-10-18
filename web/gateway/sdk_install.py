"""Request the SDK install service; the root worker installs what the release declares."""
from datetime import datetime, timezone
import json
from pathlib import Path
import threading

import toolchain_policy

CATALOG = toolchain_policy.CATALOG


class SdkInstall:
    def __init__(self, queue='/var/lib/herdr-sdk-requests',
                 state='/var/lib/herdr-sdk/status.json', catalog=None, release=None):
        self.queue, self.state, self.catalog = Path(queue), Path(state), Path(CATALOG if catalog is None else catalog)
        # The release root holds the repository's own declaration (.fvmrc), which
        # is the only place a required version is stated.
        self.release = Path(release) if release is not None else self.catalog.parents[1]
        self.lock = threading.RLock()

    def declared(self):
        """Toolchains this release can install. Empty when it ships no catalog."""
        return toolchain_policy.catalog(self.catalog)

    def toolchains(self, declared=None):
        """Every catalogued toolchain, with its requirement and whether it is present."""
        found = {}
        for name, entry in (self.declared() if declared is None else declared).items():
            version, declared_by = toolchain_policy.declared_version(entry, self.release)
            executable = toolchain_policy.expand(entry, 'executable', version) if version else None
            try:
                installed = bool(executable) and Path(executable).is_file()
            except (OSError, TypeError, ValueError):
                installed = False
            found[name] = {'label': str(entry.get('label') or name),
                           'required': version or '',
                           'declared_by': declared_by,
                           'executable': (toolchain_policy.expand(entry, 'executable', version)
                                          if version else None),
                           'installed': installed}
        return found

    def missing(self):
        return sorted(name for name, entry in self.toolchains().items()
                      if entry['required'] and not entry['installed'])

    def queued(self):
        """The toolchain a not-yet-claimed request asked for."""
        try:
            return json.loads((self.queue / 'request.json').read_text()).get('toolchain')
        except (OSError, ValueError, AttributeError):
            return None

    def progress(self, started_at=None):
        """How far the running install has come, or None.

        Written by the installer, which is the only thing that knows. Read
        leniently: a missing, stale or malformed file means no percentage, never
        a broken card. `phase` names what the bar is showing, because every
        phase but the download is an allocation rather than a measurement.
        """
        try:
            value = json.loads((self.state.parent / 'progress.json').read_text())
        except (OSError, ValueError):
            return None
        if not isinstance(value, dict):
            return None
        percent = value.get('percent')
        if type(percent) is not int or not 0 <= percent <= 100:
            return None
        try:
            recorded = datetime.fromisoformat(value['at'])
            started = datetime.fromisoformat(started_at)
            now = datetime.now(timezone.utc)
            if not started <= recorded <= now:
                return None
        except (KeyError, ValueError, TypeError):
            return None
        return {'percent': percent, 'phase': str(value.get('phase') or '')[:40],
                'at': str(value.get('at') or '')[:40]}

    def snapshot(self):
        with self.lock:
            try:
                status = json.loads(self.state.read_text()) if self.state.is_file() else {'state': 'idle'}
            except (OSError, ValueError):
                status = {'state': 'failed', 'error': 'SDK status is unreadable; inspect the installation service.'}
            if not isinstance(status, dict):
                status = {'state': 'idle'}
            if status.get('state') == 'running':
                try:
                    started = datetime.fromisoformat(status['started_at'])
                    stale = (datetime.now(timezone.utc) - started).total_seconds() > 1860
                except (KeyError, ValueError, TypeError):
                    stale = True
                if stale:
                    status = dict(status, state='failed', error='SDK installation did not finish within its service deadline; inspect the service before retrying.')
            if (self.queue / 'request.json').exists() and status.get('state') != 'running':
                status = dict(state='queued', toolchain=self.queued())
            catalog_error = None
            try:
                declared = toolchain_policy.catalog(self.catalog, strict=True)
            except ValueError as error:
                declared, catalog_error = {}, str(error)
            toolchains = self.toolchains(declared)
        return dict(status, toolchains=toolchains, catalog_error=catalog_error,
                    missing=sorted(name for name, entry in toolchains.items()
                                   if entry['required'] and not entry['installed']),
                    progress=self.progress(status.get('started_at')) if status.get('state') == 'running' else None,
                    supported=self.queue.is_dir())

    def install(self, body):
        if not isinstance(body, dict) or set(body) - {'toolchain'}:
            raise ValueError('SDK installation does not accept options.')
        with self.lock:
            info = self.snapshot()
            if not info['supported']:
                raise ValueError('Install the SDK service as root first.')
            if info['state'] in ('queued', 'running'):
                raise ValueError('An SDK installation is already running.')
            name = body.get('toolchain')
            if not self.declared():
                raise ValueError('This release does not provision any toolchain.')
            # A request must name its toolchain. Inferring it from "whatever is
            # absent" let a build blocked on one ecosystem queue an unrelated SDK
            # whenever the release happened to provision exactly one, so the
            # caller must now state the identity it verified.
            if not isinstance(name, str) or not name:
                raise ValueError('Name the toolchain to install. This release provisions: '
                                 + (', '.join(sorted(info['toolchains'])) or 'none')
                                 + '.')
            if name not in info['toolchains']:
                raise ValueError('This release does not provision that toolchain.')
            # Checked before "already installed": a toolchain with no declared
            # version is not absent, it is unprovisionable, and saying otherwise
            # sends the operator looking for the wrong problem.
            if not info['toolchains'][name]['required']:
                raise ValueError('This release declares no version for that toolchain; '
                                 'state it in the file the catalog reads before installing.')
            if name not in info['missing']:
                raise ValueError('That toolchain is already installed.')
            request = self.queue / 'request.json'
            temporary = self.queue / 'request.tmp'
            temporary.write_text(json.dumps({'action': 'install', 'toolchain': name}), encoding='utf-8')
            temporary.replace(request)
            return {'state': 'queued', 'toolchain': name,
                    'required': info['toolchains'][name]['required']}
