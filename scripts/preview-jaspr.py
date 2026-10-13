"""Loopback-only DOM migration preview using the real gateway session handlers.

Organization storage and simulated agents are disposable. Operational actions
are fixtures; no real tools, deployments or access settings are changed.
"""
import argparse
import importlib.util
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web/gateway'))
import server
from organizations import OrganizationStore

spec = importlib.util.spec_from_file_location('herdr_preview_fixture', ROOT / 'scripts/preview-agents.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


ops_spec = importlib.util.spec_from_file_location('herdr_dom_operations', ROOT / 'scripts/test-dom-fixture.py')
operations = importlib.util.module_from_spec(ops_spec)
ops_spec.loader.exec_module(operations)


class PreviewHandler(server.Handler):
    def do_GET(self):
        if self.path == '/api/resources':
            if self.authenticated():
                self.reply(200, {'available': True, 'sampled_at': 0, 'cpu_percent': 12,
                    'cpu_cores': 2, 'memory_used': 1024**3, 'memory_total': 4 * 1024**3,
                    'swap_used': 0, 'swap_total': 512 * 1024**2, 'processes': []})
            return
        if self.path.startswith('/api/'):
            response = self.server.operations.get(self.path)
            if response is not None:
                if self.authenticated(): self.reply(200, response)
                return
        if self.path.startswith('/api/notifications'):
            if self.authenticated():
                # Exercise the existing periodic-refresh fallback.
                self.reply(200, {})
            return
        if self.path.startswith('/api/') and self.path not in (
                '/api/session', '/api/snapshot', '/api/organizations/state',
                '/api/organizations/directory', '/api/organizations', '/api/organizations/export'):
            self.reply(503, {'error': 'This operation is unavailable in the DOM migration preview.'})
            return
        super().do_GET()

    def do_POST(self):
        if self.path.startswith('/api/models'):
            if self.authenticated():
                self.rfile.read(int(self.headers.get('Content-Length', '0')))
                self.reply(200, {'supports_variants': True, 'models': [
                    {'provider': 'opencode', 'id': 'big-pickle', 'name': 'Mock model', 'reasoning': []}]})
            return
        endpoints = ('updates/', 'cli-setup/', 'integration/', 'logs/', 'projects/',
                     'sdk/install', 'ssh-access/add', 'dashboard-access', 'validation/run')
        if self.path.removeprefix('/api/').startswith(endpoints):
            if not self.authenticated(): return
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
            self.reply(200, self.server.operations.post(self.path, body) or {})
            return
        if not self.path.startswith('/api/organizations/') and self.path not in ('/api/session', '/api/session/logout',
                             '/api/workspaces/create', '/api/workspaces/focus',
                             '/api/workspaces/rename'):
            self.reply(503, {'error': 'This operation is unavailable in the DOM migration preview.'})
            return
        super().do_POST()


class MockHerdr(fixture.MockHerdr):
    def command(self, *args, **kwargs):
        if args == ('agent', 'list', '--json'):
            return {'agents': list(self.agents.values())}
        if args[:2] == ('workspace', 'rename'):
            for workspace in self.workspaces:
                if workspace['workspace_id'] == args[2]:
                    workspace['label'] = args[3]
            return {}
        return super().command(*args, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8793)
    parser.add_argument('--production', action='store_true', help='Serve packaged web/public assets.')
    args = parser.parse_args()
    server.ROOT = ROOT / ('web/public' if args.production else 'web/jaspr_dashboard/build/web')
    if not (server.ROOT / 'index.html').exists():
        raise SystemExit('Run scripts/build-jaspr-dashboard.sh first.')
    with tempfile.TemporaryDirectory(prefix='herdr-dom-preview-') as directory:
        projects = Path(directory) / 'projects'
        projects.mkdir()
        mock = MockHerdr()
        server.command = mock.command
        server.PROJECTS = projects
        store = OrganizationStore(Path(directory) / 'organizations.sqlite3', projects, mock.command)

        def action(operation, **values):
            return store.action(operation, dict(request_id=uuid.uuid4().hex, **values))['id']

        org = action('save', name='DOM preview', purpose='Verify native HTML rendering', instructions='Simulated data only.')
        for name, role in [('Max', 'Developer'), ('Iris', 'Reviewer')]:
            profile = action('hire', organization_id=org, name=name, role=role,
                             persona='Preview agent.', runtime='opencode',
                             manager_id='', project=str(projects))
            action('launch', organization_id=org, profile_id=profile)
        store.worker.submit(lambda: None).result()
        http = ThreadingHTTPServer(('127.0.0.1', args.port), PreviewHandler)
        http.token = 'jaspr-preview-token'
        http.sessions = server.BrowserSessions()
        http.organizations = store
        http.operations = operations.OperationsFixture()
        print(f'DOM migration preview: http://127.0.0.1:{args.port}/\n'
              f'Demo token: jaspr-preview-token\nDemo project directory: {projects}', flush=True)
        try:
            http.serve_forever()
        finally:
            http.server_close()
            store.close()


if __name__ == '__main__':
    main()
