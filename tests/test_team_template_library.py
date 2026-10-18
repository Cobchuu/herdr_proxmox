from contextlib import closing
import copy
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
from organizations import OrganizationStore
from organization_transfer import export_configuration, import_configuration
import model_catalog
import server as gateway


class TeamTemplateLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.projects = self.root / 'projects'
        self.projects.mkdir()
        self.catalog = Mock(return_value={'runtimes': {r: model_catalog.curated(r) for r in ('claude', 'codex')}})
        self.command = Mock(side_effect=AssertionError('Library operations cannot launch agents'))
        self.store = OrganizationStore(self.root / 'org.sqlite3', self.projects, self.command, template_catalog=self.catalog)
        self.addCleanup(self.store.close)
        self.definition = dict(team_members=[
            dict(key='lead', template_role='lead_developer', name='Maya'),
            dict(key='api', template_role='backend_developer', name='API specialist'),
            dict(key='storage', template_role='backend_developer', persona='Own storage and migrations.')],
            model_policy='balanced', runtime_preferences=['codex', 'claude'],
            resource_limits=dict(max_active_sessions=2, max_active_meetings=1, daily_session_cap=10))

    def save(self, request='library-save-1', **changes):
        body = dict(action='save', request_id=request, name='API team', description='A portable API team', definition=self.definition)
        body.update(changes)
        return self.store.template_library(body, 'Rick Richter')

    def create(self, saved, request):
        body = dict(request_id=request, name=request, purpose='Build', project=str(self.projects),
                    template_id=saved['id'], template_version=saved['version'])
        preview = self.store.team_plan(body)
        return self.store.action('save', dict(body, template_plan=preview['template_plan']))['id']

    def test_save_replay_immutable_versions_and_pinned_organizations(self):
        first = self.save()
        self.assertEqual(first, self.save())
        self.assertEqual(first['version'], 1)
        self.assertEqual(first['definition']['team_members'][1]['manager_key'], 'lead')
        self.assertTrue(first['definition']['team_members'][1]['persona'])
        self.assertNotIn('model', first['definition']['team_members'][1])
        org = self.create(first, 'organization-v1')
        before = [p for p in self.store.profile_records() if p['organization_id'] == org]
        changed = copy.deepcopy(self.definition)
        changed['team_members'][1]['name'] = 'API v2'
        second = self.save('library-save-2', template_id=first['id'], expected_version=1, definition=changed)
        self.assertEqual(second['version'], 2)
        old = self.store.template_library(dict(action='read', template_id=first['id'], version=1), '')
        self.assertEqual(old['definition'], first['definition'])
        self.assertEqual(old['latest_version'], 2)
        self.assertEqual([p for p in self.store.profile_records() if p['organization_id'] == org], before)
        self.assertEqual(self.store.organization_records()[0]['source_template']['version'], 1)
        newer_org = self.create(second, 'organization-v2')
        self.assertIn('API v2', [p['name'] for p in self.store.profile_records() if p['organization_id'] == newer_org])
        self.assertEqual(len(self.store.saved_templates()[0]['versions']), 2)
        self.command.assert_not_called()

    def test_stale_version_duplicate_request_and_nonportable_fields_are_rejected(self):
        first = self.save()
        self.save('library-version-2', template_id=first['id'], expected_version=1)
        with self.assertRaisesRegex(ValueError, 'newer version'):
            self.save('library-stale', template_id=first['id'], expected_version=1)
        with self.assertRaisesRegex(ValueError, 'different content'):
            self.save(name='Different')
        for change in ({'project': str(self.projects)}, {'accounts': {'key': 'secret'}}, {'resource_limits': {'daily_session_cap': True}}):
            content = dict(self.definition, **change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.save('invalid-portable', name='Invalid', definition=content)
        with self.assertRaisesRegex(ValueError, 'cycles'):
            content = copy.deepcopy(self.definition)
            content['team_members'][0]['manager_key'] = 'api'
            self.save('invalid-cycle', name='Cycle', definition=content)
        self.assertEqual(len(self.store.saved_templates()), 1)

    def test_backup_round_trip_versions_and_conflicts_roll_back(self):
        first = self.save()
        self.save('backup-version-2', template_id=first['id'], expected_version=1)
        bundle = export_configuration(self.store)
        destination = OrganizationStore(self.root / 'restored.sqlite3', self.projects, self.command, template_catalog=self.catalog)
        self.addCleanup(destination.close)
        import_configuration(destination, bundle)
        import_configuration(destination, bundle)
        restored = destination.template_library(dict(action='read', template_id=first['id'], version=1), '')
        self.assertEqual(restored['definition'], first['definition'])
        self.assertEqual(destination.saved_templates()[0]['version'], 2)
        corrupt = copy.deepcopy(bundle)
        corrupt['team_template_versions'][0]['definition']['team_members'][0]['name'] = 'Tampered'
        with self.assertRaises(ValueError):
            import_configuration(destination, corrupt)
        incomplete = copy.deepcopy(bundle)
        incomplete['team_template_versions'] = incomplete['team_template_versions'][1:]
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            import_configuration(destination, incomplete)

    def test_template_availability_is_rechecked_for_each_new_project(self):
        saved = self.save()
        self.catalog.return_value = {'runtimes': {}}
        with self.assertRaisesRegex(ValueError, 'No ready CLI'):
            self.create(saved, 'unavailable-team')
        self.assertEqual(self.store.organization_records(), [])
        self.assertEqual(self.store.saved_templates()[0]['version'], 1)

    def test_native_claude_provider_and_model_identifiers_are_normalized(self):
        content = copy.deepcopy(self.definition)
        content['team_members'][1].update(runtime='claude', provider='anthropic', model=' claude-sonnet-5-5 ')
        saved = self.save(definition=content)
        self.assertEqual(saved['definition']['team_members'][1]['model'], 'claude-sonnet-5-5')
        org = self.create(saved, 'claude-native-team')
        profile = next(p for p in self.store.profile_records() if p['organization_id'] == org and p['template_key'] == 'api')
        self.assertEqual(profile['model'], 'claude-sonnet-5-5')

    def test_authenticated_http_library_catalog_and_operator_write_boundary(self):
        server = gateway.ThreadingHTTPServer(('127.0.0.1', 0), gateway.Handler)
        server.token, server.organizations = 'a' * 48, self.store
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f'http://127.0.0.1:{server.server_port}/api/organizations/templates'
        headers = {'Authorization': 'Bearer ' + server.token, 'Content-Type': 'application/json'}
        with self.assertRaises(HTTPError) as error:
            urlopen(base)
        self.assertEqual(error.exception.code, 401)
        body = dict(action='save', request_id='http-library-save', name='HTTP team', definition=self.definition)
        saved = json.load(urlopen(Request(base + '/library', headers=headers, data=json.dumps(body).encode())))
        listing = json.load(urlopen(Request(base, headers=headers)))
        self.assertEqual(listing['saved_templates'][0]['id'], saved['id'])
        loaded = json.load(urlopen(Request(base + '/library', headers=headers,
            data=json.dumps(dict(action='read', template_id=saved['id'], version=1)).encode())))
        self.assertEqual(loaded['definition'], saved['definition'])
        # The authenticated operator identity is read independently from tokens.
        original = gateway.Handler.authenticated
        from unittest.mock import patch
        def operator(handler):
            ok = original(handler)
            if ok:
                handler.operator = {'name': 'operator', 'role': 'operator'}
            return ok
        with patch.object(gateway.Handler, 'authenticated', operator):
            with self.assertRaises(HTTPError):
                urlopen(Request(base + '/library', headers=headers, data=json.dumps(dict(body, request_id='operator-library')).encode()))
        self.assertEqual(len(self.store.saved_templates()), 1)


if __name__ == '__main__':
    unittest.main()
