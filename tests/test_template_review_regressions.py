"""Lifecycle, transfer and credential regressions from the template review."""
from contextlib import closing, contextmanager
import copy
import json
import threading
import unittest
from unittest.mock import MagicMock, patch
from urllib.request import Request, urlopen

import test_team_template_library as library_cases
import test_template_workflows as workflow_cases
import test_contributions as contribution_cases
import team_templates
import team_template_library
import template_workflows
from integration_coordinator import IntegrationCoordinator
from organization_transfer import export_configuration, import_configuration
from request_identity import ORGANIZATION_REQUEST, TASK_REQUEST
import server


@contextmanager
def fixture(case_type):
    case = case_type()
    try:
        case.setUp()
        yield case
    finally:
        case.doCleanups()


class TemplateReviewRegressions(unittest.TestCase):
    def test_read_paths_do_not_sync_or_take_the_coordinator_writer_lock(self):
        with fixture(workflow_cases.TemplateWorkflowTests) as case:
            coordinator = IntegrationCoordinator(case.root / 'integration.sqlite3', case.store)
            case.addCleanup(coordinator.close)
            with patch.object(coordinator, 'sync_template_workflows', side_effect=AssertionError('read must not sync')):
                with patch.object(case.store, 'organization_records', side_effect=AssertionError('read must not scan organizations')):
                    self.assertEqual(len(coordinator.configuration_records()), 1)
                    self.assertEqual(len(coordinator.snapshot()['configurations']), 1)
            with patch('template_workflows.coordinator_configurations', side_effect=AssertionError('unchanged metadata must not rescan')):
                coordinator.sync_template_workflows()
                coordinator.observe([])

    def test_removed_generated_coordinator_is_disabled_then_replaced(self):
        with fixture(workflow_cases.TemplateWorkflowTests) as case:
            coordinator = IntegrationCoordinator(case.root / 'integration.sqlite3', case.store)
            case.addCleanup(coordinator.close)
            old = coordinator.configuration_records()[0]
            case.store.action('remove_agent', dict(request_id='remove-template-coordinator',
                organization_id=case.org, profile_id=old['profile_id']))
            coordinator.sync_template_workflows()
            self.assertFalse(coordinator.configuration_records()[0]['enabled'])
            new_org = case.store.action('save', dict(case.body, request_id='replacement-template-team'))['id']
            coordinator.sync_template_workflows()
            replacement = coordinator.configuration_records()[0]
            self.assertTrue(replacement['enabled'])
            self.assertEqual(replacement['organization_id'], new_org)
            self.assertNotEqual(replacement['profile_id'], old['profile_id'])
            coordinator.configure(dict(repository='repo', enabled=False))
            case.store.action('save', dict(case.body, request_id='third-template-team'))
            coordinator.sync_template_workflows()
            self.assertFalse(coordinator.configuration_records()[0]['enabled'])
            self.assertNotIn('template_organization_id', coordinator.configuration_records()[0])
            legacy = dict(coordinator.configuration_records()[0], template_organization_id=new_org, auto_sdk=True)
            with closing(coordinator.connect()) as db, db:
                db.execute('UPDATE settings SET data=? WHERE repository=?', (json.dumps(legacy), 'repo'))
            restarted = IntegrationCoordinator(case.root / 'integration.sqlite3', case.store)
            case.addCleanup(restarted.close)
            restored = restarted.configuration_records()[0]
            self.assertFalse(restored['enabled'])
            self.assertTrue(restored['auto_sdk'])
            self.assertNotIn('template_organization_id', restored)

    def test_missing_coordinator_project_is_not_resolved_as_cwd(self):
        with fixture(workflow_cases.TemplateWorkflowTests) as case:
            profile = dict(case.profiles['integration_engineer'], project='')
            with case.store.lock, closing(case.store.connect()) as db, db:
                case.store.put(db, 'profiles', profile)
            self.assertEqual(template_workflows.coordinator_configurations(case.store), [])

    def test_lightweight_markers_cannot_bypass_coding_role_floor(self):
        for identifier in ('coder-lite-free', 'codex-mini', 'qwen-flash', 'max-nano'):
            with self.subTest(identifier=identifier):
                models = dict(runtimes={'opencode': dict(models=[dict(id=identifier, provider='test',
                    reasoning=[], context=64000, tool_call=True, cost=dict(input=0, output=0))])})
                with self.assertRaisesRegex(ValueError, 'capability requirements'):
                    team_templates.selection(team_templates.BY_ID['lead_developer'], 'economy', models)
                self.assertEqual(team_templates.selection(team_templates.BY_ID['qa_engineer'], 'economy', models)['model'], identifier)

    def test_provider_without_model_is_rejected_before_saving(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            definition = copy.deepcopy(case.definition)
            definition['team_members'][0].update(runtime='codex', provider='custom')
            with self.assertRaisesRegex(ValueError, 'Select a model'):
                case.save(definition=definition)
            self.assertEqual(case.store.saved_templates(), [])

    def test_preset_provenance_survives_library_create_and_ordinary_edit(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            saved = case.save(definition=dict(team_preset='small_product'))
            self.assertEqual(saved['definition']['team_preset'], 'small_product')
            body = dict(request_id='create-from-preset', name='Preset team', purpose='Build',
                project=str(case.projects), template_id=saved['id'], template_version=1)
            preview = case.store.team_plan(body)
            with patch('team_template_library.read', wraps=team_template_library.read) as read:
                with patch.object(case.store, 'put', wraps=case.store.put) as put:
                    org = case.store.action('save', dict(body, template_plan=preview['template_plan']))['id']
            self.assertEqual(read.call_count, 1)
            self.assertEqual(sum(c.args[1] == 'organizations' for c in put.call_args_list), 1)
            case.store.action('save', dict(request_id='edit-existing-preset', id=org, name='Renamed', purpose='Build'))
            self.assertEqual(case.store.organization_records()[0]['team_preset'], 'small_product')

    def test_template_catalog_projects_metadata_in_two_queries(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            saved = case.save()
            case.save('template-version-2', template_id=saved['id'], expected_version=1, name='API team v2')
            queries = []
            with closing(case.store.connect()) as db:
                db.set_trace_callback(queries.append)
                listing = team_template_library.catalog(db)
            self.assertEqual(len(queries), 2)
            self.assertEqual([v['name'] for v in listing[0]['versions']], ['API team v2', 'API team'])
            self.assertIn('json_extract', queries[0])

    def test_export_uses_one_snapshot_and_import_reports_library_counts(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            case.save()
            queries = []
            original = case.store.connect
            def connect():
                db = original()
                db.set_trace_callback(queries.append)
                return db
            with patch.object(case.store, 'connect', side_effect=connect) as connections:
                exported = export_configuration(case.store)
            self.assertEqual(connections.call_count, 1)
            self.assertEqual(queries[0], 'BEGIN')
            self.assertIn('COMMIT', queries)
            imported = import_configuration(case.store, exported)['imported']
            self.assertEqual(imported['team_templates'], 1)
            self.assertEqual(imported['team_template_versions'], 1)
            with patch('organization_transfer.MAX_TRANSFER_BYTES', 1000):
                with self.assertRaisesRegex(ValueError, 'No records were omitted'):
                    export_configuration(case.store)
            self.assertEqual(len(case.store.saved_templates()), 1)

    def test_valid_large_unicode_roster_passes_the_http_size_gate(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            gateway = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
            gateway.token, gateway.organizations = 'a' * 48, case.store
            thread = threading.Thread(target=gateway.serve_forever, daemon=True)
            thread.start()
            try:
                body = dict(project=str(case.projects), team_members=[
                    dict(key='member-' + str(n), template_role='backend_developer', persona='界' * 6000)
                    for n in range(team_templates.MAX_MEMBERS)])
                escaped = dict(body, team_members=[dict(m, runtime='opencode', persona='😀' * 6000,
                    accessible_paths=['/' + '😀' * 499] * 20) for m in body['team_members']])
                self.assertLessEqual(len(json.dumps(escaped).encode()), team_templates.MAX_REQUEST_BYTES)
                planned = team_templates.plan(escaped, dict(runtimes={'opencode': dict(models=[
                    dict(id='coder', provider='example', name='Coder', reasoning=[])])}))
                self.assertEqual(len(planned['members']), 20)
                encoded = json.dumps(body, ensure_ascii=False).encode()
                self.assertGreater(len(encoded), 256000)
                response = json.load(urlopen(Request(f'http://127.0.0.1:{gateway.server_port}/api/organizations/templates',
                    headers={'Authorization': 'Bearer ' + gateway.token, 'Content-Type': 'application/json'}, data=encoded)))
                self.assertEqual(len(response['members']), 20)
            finally:
                gateway.shutdown()
                gateway.server_close()
                thread.join()

    def test_export_counts_records_across_tables_before_loading_the_next_table(self):
        with fixture(library_cases.TeamTemplateLibraryTests) as case:
            with closing(case.store.connect()) as db, db:
                for table in ('organizations', 'profiles', 'groups'):
                    record = dict(id=table, organization_id='organizations', name='x' * 500)
                    case.store.put(db, table, record)
            queries = []
            original = case.store.connect
            def connect():
                db = original()
                db.set_trace_callback(queries.append)
                return db
            with patch.object(case.store, 'connect', side_effect=connect):
                with patch('organization_transfer.MAX_TRANSFER_BYTES', 1000):
                    with self.assertRaisesRegex(ValueError, 'No records were omitted'):
                        export_configuration(case.store)
            self.assertIn('SELECT data FROM profiles ORDER BY rowid', queries)
            self.assertNotIn('SELECT data FROM groups ORDER BY rowid', queries)

    def test_shared_request_alphabet_preserves_endpoint_length_contracts(self):
        self.assertIsNotNone(ORGANIZATION_REQUEST.fullmatch('a' * 32))
        self.assertIsNotNone(TASK_REQUEST.fullmatch('a' * 32))
        self.assertIsNotNone(TASK_REQUEST.fullmatch('short'))
        self.assertIsNone(ORGANIZATION_REQUEST.fullmatch('short'))
        self.assertIsNone(TASK_REQUEST.fullmatch('a' * 65))
        self.assertIsNone(ORGANIZATION_REQUEST.fullmatch('a' * 81))

    def test_unchanged_pr_identity_is_not_requeried_on_configuration_save(self):
        with fixture(contribution_cases.GitHubTests) as case:
            with patch.object(case.api, 'request', side_effect=case.split_response):
                case.api.configure(case.split_body())
            with patch.object(case.api, 'request', side_effect=case.split_response) as request:
                case.api.configure(case.split_body())
            self.assertFalse(any(c.args[0] == '/user' and c.kwargs.get('token') == case.split_body()['pr_token']
                                 for c in request.call_args_list))
            with patch.object(case.api, 'request', side_effect=case.split_response) as request:
                preflight = case.api.publication_preflight('owner/repo', 'contributor/repo')
            request.assert_any_call('/user', token=case.split_body()['pr_token'])
            self.assertEqual(preflight['upstream_pr_creation'], 'not_exercised')

    def test_fork_pr_reads_use_push_token_and_upstream_reads_use_pr_token(self):
        with fixture(contribution_cases.GitHubTests) as case:
            with patch.object(case.api, 'request', side_effect=case.split_response):
                case.api.configure(case.split_body())
            opener = MagicMock()
            response = opener.open.return_value.__enter__.return_value
            response.read.return_value, response.headers = b'[]', {}
            with patch('github_api.build_opener', return_value=opener):
                case.api.request('/repos/contributor/repo/pulls?state=open')
                self.assertEqual(opener.open.call_args.args[0].get_header('Authorization'), 'Bearer ' + case.split_body()['token'])
                case.api.find_pull('owner/repo', 'branch', 'contributor')
                self.assertEqual(opener.open.call_args.args[0].get_header('Authorization'), 'Bearer ' + case.split_body()['pr_token'])

    def test_pr_input_errors_precede_malformed_stored_configuration(self):
        with fixture(contribution_cases.GitHubTests) as case:
            malformed = '{malformed credential file'
            case.path.write_text(malformed, encoding='utf-8')
            with patch.object(case.api, 'configuration', wraps=case.api.configuration) as configuration:
                with patch.object(case.api, 'request', side_effect=AssertionError('invalid input must not reach GitHub')) as request:
                    with self.assertRaisesRegex(ValueError, 'Remove or replace the pull request credential'):
                        case.api.configure(dict(case.split_body(), clear_pr_credential=True))
                    with self.assertRaisesRegex(ValueError, 'valid pull request personal access token'):
                        case.api.configure(dict(case.split_body(), pr_token='short'))
                request.assert_not_called()
                configuration.assert_not_called()
            self.assertEqual(case.path.read_text(encoding='utf-8'), malformed)
