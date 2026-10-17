"""Queue the release's fixed build-service installer for the root worker."""
from datetime import datetime, timezone
import json
from pathlib import Path
import threading

DEADLINE_SECONDS = 660  # Also enforced by the standalone root worker.


class BuildServiceInstall:
    def __init__(self, queue='/var/lib/herdr-build-install-requests',
                 state='/var/lib/herdr-build-install/status.json'):
        self.queue, self.state = Path(queue), Path(state)
        self.lock = threading.RLock()

    def snapshot(self):
        with self.lock:
            # The worker publishes running before removing the request. Read
            # the request first so a claim cannot appear as an idle interval.
            try:
                requested_at = (self.queue / 'request.json').stat().st_mtime
            except FileNotFoundError:
                requested_at = None
            try:
                status = json.loads(self.state.read_text(encoding='utf-8')) if self.state.is_file() else {'state': 'idle'}
                if not isinstance(status, dict):
                    raise ValueError('Invalid installation status.')
            except (OSError, ValueError):
                status = dict(state='failed', error='Build-service installation status is unreadable; inspect herdr-build-install.service.')
            if status.get('state') == 'running':
                try:
                    started = datetime.fromisoformat(status['started_at'])
                    stale = (datetime.now(timezone.utc) - started).total_seconds() > DEADLINE_SECONDS
                except (KeyError, TypeError, ValueError):
                    stale = True
                if stale:
                    status = dict(state='failed', error='Build-service installation exceeded its deadline; inspect herdr-build-install.service before retrying.')
            if requested_at is not None and status.get('state') != 'running':
                if datetime.now(timezone.utc).timestamp() - requested_at > DEADLINE_SECONDS:
                    status = dict(state='failed', error='Build-service installation did not start before its deadline. '
                                  'Inspect herdr-build-install.path and retry installation.')
                else:
                    status = dict(state='queued')
            return dict(status, supported=self.queue.is_dir())

    def install(self, body, validation):
        if not isinstance(body, dict) or body:
            raise ValueError('Build-service installation does not accept options.')
        with self.lock:
            info = self.snapshot()
            if not info['supported']:
                raise ValueError('Update the container installation to enable dashboard build-service installation.')
            if info['state'] in ('queued', 'running'):
                raise ValueError('Build-service installation is already queued or running.')
            current = validation.snapshot()
            if current.get('executor') == 'service':
                raise ValueError('The durable build service is already configured.')
            if (current.get('running', 0) or current.get('queued', 0)
                    or any(run.get('state') in ('queued', 'running') for run in current.get('runs', []))):
                raise ValueError('Wait for current builds to finish before installing the build service; the gateway restarts.')
            temporary = self.queue / 'request.tmp'
            temporary.write_text(json.dumps({'action': 'install'}), encoding='utf-8')
            temporary.replace(self.queue / 'request.json')
            return dict(state='queued')

    def require_idle(self):
        if self.snapshot()['state'] in ('queued', 'running'):
            raise ValueError('Wait for build-service installation to finish before starting a build.')
