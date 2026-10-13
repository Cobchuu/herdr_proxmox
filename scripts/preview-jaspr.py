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
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web/gateway'))
import server
import organizations
from organizations import OrganizationStore

# Every command in this preview targets MockHerdr. Provider-specific permission
# files would configure the user's real CLI, so the simulated launch adapter
# omits them. The production gateway and store implementation stay unchanged.
organizations.prepare_permissions = lambda profile, state_path, **kwargs: []

spec = importlib.util.spec_from_file_location('herdr_preview_fixture', ROOT / 'scripts/preview-agents.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


ops_spec = importlib.util.spec_from_file_location('herdr_dom_operations', ROOT / 'scripts/test-dom-fixture.py')
operations = importlib.util.module_from_spec(ops_spec)
ops_spec.loader.exec_module(operations)


class PreviewHandler(server.Handler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/api/resources':
            if self.authenticated():
                self.reply(200, {'available': True, 'sampled_at': 0, 'cpu_percent': 12,
                    'cpu_cores': 2, 'memory_used': 1024**3, 'memory_total': 4 * 1024**3,
                    'swap_used': 0, 'swap_total': 512 * 1024**2, 'processes': []})
            return
        if path.startswith('/api/'):
            response = self.server.operations.get(self.path)
            if response is not None:
                if self.authenticated(): self.reply(200, response)
                return
        if path == '/api/notifications':
            if self.authenticated():
                # Exercise the existing periodic-refresh fallback.
                self.reply(200, {})
            return
        if path.startswith('/api/') and path not in (
                '/api/session', '/api/snapshot', '/api/organizations/state',
                '/api/organizations/directory', '/api/organizations', '/api/organizations/export'):
            self.reply(503, {'error': 'This operation is unavailable in the DOM migration preview.'})
            return
        if path in ('/api/session', '/api/snapshot', '/api/organizations/state',
                    '/api/organizations/directory', '/api/organizations', '/api/organizations/export'):
            self.path = path
        super().do_GET()

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == '/api/models':
            if self.authenticated():
                self.rfile.read(int(self.headers.get('Content-Length', '0')))
                self.reply(200, {'supports_variants': True, 'models': [
                    {'provider': 'opencode', 'id': 'big-pickle', 'name': 'Mock model', 'reasoning': []}]})
            return
        endpoints = ('updates/', 'cli-setup/', 'integration/', 'logs/', 'projects/',
                     'sdk/install', 'ssh-access/add', 'dashboard-access', 'validation/run')
        if path.removeprefix('/api/').startswith(endpoints):
            if not self.authenticated(): return
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
            self.reply(200, self.server.operations.post(self.path, body) or {})
            return
        if not path.startswith('/api/organizations/') and path not in ('/api/session', '/api/session/logout',
                             '/api/workspaces/create', '/api/workspaces/focus',
                             '/api/workspaces/rename'):
            self.reply(503, {'error': 'This operation is unavailable in the DOM migration preview.'})
            return
        self.path = path
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


def seed_preview(store, projects, mock):
    """Create real disposable records; runtime responses remain simulation."""
    def action(operation, **values):
        return store.action(operation, dict(request_id=uuid.uuid4().hex, **values))['id']

    demo = projects / 'demo'
    demo.mkdir()
    (demo / 'README.md').write_text('# Native DOM fixture\n\nSimulated QA data, never production work.\n', encoding='utf-8')
    org = action('save', name='DOM preview team', purpose='Review the native dashboard with simulated work.',
                 instructions='Fixture-only sample data. Never use these records as production evidence.')
    profiles = {}
    for name, role, manager in [
            ('Nova', 'Engineering lead', None),
            ('Max', 'Developer', 'Nova'),
            ('Iris', 'Reviewer', 'Nova'),
            ('Quinn', 'QA engineer', 'Nova'),
            ('Sage', 'Integration coordinator', 'Iris'),
            ('Eli', 'Worktree developer', 'Max')]:
        profiles[name] = action('hire', organization_id=org, name=name, role=role,
                               persona='Simulated preview agent: ' + role + '.', runtime='opencode',
                               manager_id=profiles.get(manager, ''), project=str(demo), use_worktree=True)
        action('launch', organization_id=org, profile_id=profiles[name])
    store.wait_idle(timeout=30)
    action('group', organization_id=org, name='Product & implementation',
           description='Fixture-only collaboration between the lead and developers.',
           members=[profiles['Nova'], profiles['Max'], profiles['Eli']], read_only=True)
    action('group', organization_id=org, name='Quality & integration',
           description='Fixture-only QA, review and integration evidence discussion.',
           members=[profiles['Iris'], profiles['Quinn'], profiles['Sage']], read_only=True)
    store.wait_idle(timeout=30)

    # Update the mock live identities only after the real store recorded each
    # launch alias, pane and conversation. snapshot/label_agents still apply
    # their production ownership verification before publishing these states.
    statuses = {'Nova': 'idle', 'Max': 'working', 'Iris': 'blocked',
                'Quinn': 'done', 'Sage': 'idle', 'Eli': 'working'}
    records = store.snapshot(live_status=False)
    by_id = {profile_id: name for name, profile_id in profiles.items()}
    for job in records['jobs']:
        name = by_id.get(job.get('profile_id'))
        if job.get('kind') != 'launch' or not name:
            continue
        agent = mock.agents.get(job.get('alias'))
        if agent:
            agent['agent_status'] = statuses[name]
            agent['interactive_ready'] = statuses[name] in ('idle', 'done')
            agent['cwd'] = str(demo)
            mock.outputs[job['alias']] = ('Fixture-only ' + name + ': ' + statuses[name] +
                                          '\nAllow the simulated review action? Enter or Escape.' if statuses[name] == 'blocked'
                                          else 'Fixture-only ' + name + ': ' + statuses[name] + '.')
    operation_fixture = operations.OperationsFixture()
    task_links = operation_fixture.seed_task_evidence(store.snapshot())
    for job in records['jobs']:
        task_id = task_links.get(job.get('profile_id'))
        if job.get('kind') == 'launch' and task_id:
            store.update_job(job['id'], task_id=task_id, fixture_only=True)
    # Refresh session summaries now that actual launch records carry task IDs.
    operation_fixture.seed_task_evidence(store.snapshot())
    return operation_fixture


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

        operation_fixture = seed_preview(store, projects, mock)
        http = ThreadingHTTPServer(('127.0.0.1', args.port), PreviewHandler)
        http.token = 'jaspr-preview-token'
        http.sessions = server.BrowserSessions()
        http.organizations = store
        http.operations = operation_fixture
        print(f'DOM migration preview: http://127.0.0.1:{args.port}/\n'
              f'Demo token: jaspr-preview-token\nDemo project directory: {projects}\n'
              'Fixture-only: six managed agents, two groups and six sample tasks.\n'
              'Task links show recorded follow-up provenance or execution waits; no inferred prerequisites.', flush=True)
        try:
            http.serve_forever()
        finally:
            http.server_close()
            store.close()


if __name__ == '__main__':
    main()
