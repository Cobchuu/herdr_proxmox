import json
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import model_catalog
import team_templates as templates
from organizations import OrganizationStore, launch_arguments


def available(**extra):
    return {'runtimes': {runtime: model_catalog.curated(runtime) for runtime in ('claude', 'codex')} | extra}


class TeamTemplateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.projects = self.root / 'projects'
        self.projects.mkdir()
        self.catalog = Mock(return_value=available())
        self.command = Mock(side_effect=AssertionError('Creating profiles must not send CLI prompts'))
        self.store = OrganizationStore(self.root / 'org.sqlite3', self.projects, self.command,
                                       template_catalog=self.catalog)
        self.addCleanup(self.store.close)
        self.body = dict(request_id='preset-create-001', name='Engineering', purpose='Build tools',
                         instructions='Follow evidence', project=str(self.projects),
                         template_roles=['backend_developer', 'reviewer', 'lead_developer', 'integration_engineer'])

    def test_atomic_creation_hierarchy_defaults_and_persistence(self):
        preview = self.store.team_plan(self.body)
        body = dict(self.body, template_plan=preview['template_plan'])
        result = self.store.action('save', body)
        snapshot = self.store.snapshot(live_status=False)
        profiles = {p['template_role']: p for p in snapshot['profiles']}
        self.assertEqual(len(profiles), 4)
        lead = profiles['lead_developer']
        self.assertEqual(lead['manager_id'], '')
        self.assertEqual(profiles['reviewer']['manager_id'], '')
        for role in ('backend_developer', 'integration_engineer'):
            self.assertEqual(profiles[role]['manager_id'], lead['id'])
        for profile in profiles.values():
            self.assertEqual(profile['organization_id'], result['id'])
            self.assertTrue(profile['use_worktree'])
            self.assertEqual(profile['permission_mode'], 'default')
            self.assertEqual(profile['accessible_paths'], [])
            self.assertEqual(profile['version'], 1)
            self.assertIn('Report', profile['persona'])
            self.assertTrue(launch_arguments(profile))
        self.assertEqual(snapshot['jobs'], [])
        with closing(sqlite3.connect(self.store.path)) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM profiles').fetchone()[0], 4)
        self.command.assert_not_called()
        # A retry works even when every CLI has disappeared since creation.
        self.catalog.side_effect = ValueError('Account gone')
        self.assertEqual(self.store.action('save', body), result)
        self.assertEqual(len(self.store.profile_records()), 4)
        with self.assertRaisesRegex(ValueError, 'different content'):
            self.store.action('save', dict(body, name='Other'))

    def test_failed_profile_write_rolls_back_org_profiles_and_request(self):
        original = self.store.put
        calls = 0
        def put(db, table, item):
            nonlocal calls
            if table == 'profiles':
                calls += 1
                if calls == 2:
                    raise ValueError('simulated disk error')
            return original(db, table, item)
        with patch.object(self.store, 'put', side_effect=put):
            with self.assertRaisesRegex(ValueError, 'disk error'):
                self.store.action('save', self.body)
        with closing(sqlite3.connect(self.store.path)) as db:
            for table in ('organizations', 'profiles', 'requests'):
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table}').fetchone()[0], 0)
        self.store.action('save', self.body)
        self.assertEqual(len(self.store.profile_records()), 4)

    def test_no_lead_reports_to_owner_and_edit_does_not_recreate_team(self):
        body = dict(self.body, template_roles=['frontend_developer'])
        result = self.store.action('save', body)
        profile = self.store.profile_records()[0]
        self.assertEqual(profile['manager_id'], '')
        self.assertIn('Report directly to the organization owner', profile['persona'])
        edit = dict(request_id='preset-edit-001', id=result['id'], name='Renamed', purpose='Still build', instructions='')
        self.store.action('save', edit)
        self.assertEqual(len(self.store.profile_records()), 1)
        self.assertEqual(self.store.snapshot(live_status=False)['organizations'][0]['template_roles'], ['frontend_developer'])
        with self.assertRaisesRegex(ValueError, 'only.*creating'):
            self.store.action('save', dict(edit, request_id='preset-edit-002', template_roles=['reviewer']))

    def test_invalid_roles_paths_policy_or_accounts_create_nothing(self):
        for change in (dict(template_roles=['unknown']), dict(template_roles=['reviewer', 'reviewer']),
                       dict(template_roles={}), dict(template_roles=None), dict(model_policy=[]),
                       dict(project=str(self.root)), dict(project='')):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.store.action('save', dict(self.body, **change))
        self.catalog.return_value = {'runtimes': {}}
        with self.assertRaisesRegex(ValueError, 'No ready CLI'):
            self.store.action('save', self.body)
        self.assertEqual(self.store.snapshot(live_status=False)['organizations'], [])

    def test_empty_org_does_not_require_accounts_or_project(self):
        self.store.template_catalog = None
        self.store.action('save', dict(self.body, template_roles=[], project=''))
        self.assertEqual(len(self.store.snapshot(live_status=False)['organizations']), 1)
        self.assertEqual(self.store.profile_records(), [])

    def test_account_change_invalidates_preview_without_partial_creation(self):
        preview = self.store.team_plan(self.body)
        self.catalog.return_value = available(claude={'models': []})
        with self.assertRaisesRegex(ValueError, 'changed since.*preview'):
            self.store.action('save', dict(self.body, template_plan=preview['template_plan']))
        self.assertEqual(self.store.profile_records(), [])
        self.assertEqual(self.store.snapshot(live_status=False)['organizations'], [])

    def test_model_validation_failure_aborts_creation(self):
        self.store.model_validator = Mock(side_effect=ValueError('Model unavailable'))
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            self.store.action('save', self.body)
        self.assertEqual(self.store.snapshot(live_status=False)['organizations'], [])

    def test_cost_policies_families_and_supported_efforts(self):
        for runtime, ordinary, strong in [('claude', 'haiku', 'opus'), ('codex', 'luna', 'astra')]:
            catalogs = {'runtimes': {runtime: model_catalog.curated(runtime)}}
            basic = templates.selection(templates.BY_ID['backend_developer'], 'balanced', catalogs)
            advanced = templates.selection(templates.BY_ID['reviewer'], 'capability', catalogs)
            self.assertIn(ordinary, basic['model'])
            self.assertIn(strong, advanced['model'])
            self.assertEqual(basic['reasoning'], 'medium')
            self.assertEqual(advanced['reasoning'], 'high')
            lead = templates.selection(templates.BY_ID['lead_developer'], 'balanced', catalogs)
            self.assertTrue('sonnet' in lead['model'] or 'sol' in lead['model'])

    def test_opencode_free_preference_cost_metadata_and_variant_fallback(self):
        models = model_catalog.parse_models(
            'zen/expensive\n{"cost":{"input":8,"output":20}}\n'
            'zen/coder-free\n{"cost":{"input":0,"output":0},"variants":{"high":{}}}\n'
            'zen/paid-free\n{"cost":{"input":2,"output":3}}\n')
        self.assertEqual(models[0]['cost'], {'input': 8, 'output': 20})
        self.assertFalse(templates.is_free(models[2]))
        self.assertFalse(templates.is_free({'id': 'paid-free', 'cost': {'input': 2}}))
        catalogs = available(opencode={'models': models, 'supports_variants': True})
        selected = templates.selection(templates.BY_ID['reviewer'], 'economy', catalogs)
        self.assertEqual((selected['runtime'], selected['model'], selected['reasoning']), ('opencode', 'coder-free', 'high'))
        catalogs['runtimes']['opencode']['supports_variants'] = False
        self.assertEqual(templates.selection(templates.BY_ID['reviewer'], 'economy', catalogs)['reasoning'], '')
        for cost in ({'input': True, 'output': 0}, {'input': -1, 'output': 0}, {'input': float('nan'), 'output': 0}, {'input': 0}):
            self.assertIsNone(templates.price({'cost': cost}))

    def test_non_tool_models_are_excluded_and_project_change_invalidates_preview(self):
        models = model_catalog.parse_models('zen/image-free\n{"cost":{"input":0,"output":0},"capabilities":{"toolcall":false}}\n')
        catalogs = available(opencode={'models': models})
        selected = templates.selection(templates.BY_ID['reviewer'], 'economy', catalogs)
        self.assertNotEqual(selected['runtime'], 'opencode')
        preview = self.store.team_plan(self.body)
        other = self.projects / 'other'
        other.mkdir()
        with self.assertRaisesRegex(ValueError, 'changed since.*preview'):
            self.store.action('save', dict(self.body, project=str(other), template_plan=preview['template_plan']))
        self.assertEqual(self.store.profile_records(), [])

    def test_catalog_filters_unready_accounts_and_accepts_opencode_config(self):
        cli = Mock()
        cli.status.side_effect = lambda r: {'installed': True, 'status': 'not_configured' if r in ('codex', 'opencode') else 'configured'}
        cli.ready.side_effect = lambda r: 'Integration missing' if r == 'claude' else None
        live = {'models': [{'provider': 'custom', 'id': 'coder', 'reasoning': []}], 'stale': True}
        with patch.object(model_catalog, 'discover_models', return_value=live):
            result = templates.catalog(cli, self.projects, str(self.projects))
        self.assertEqual(set(result['runtimes']), {'opencode', 'agy'})
        self.assertEqual(result['runtimes']['opencode']['models'], live['models'])
        self.assertTrue(result['warnings'])
        with patch.object(model_catalog, 'discover_models', side_effect=ValueError('Discovery failure')):
            result = templates.catalog(cli, self.projects, str(self.projects))
        self.assertEqual(set(result['runtimes']), {'agy'})

    def test_antigravity_uses_only_cli_defaults(self):
        cli = Mock()
        cli.status.side_effect = lambda r: {'installed': r == 'agy', 'status': 'unknown'}
        cli.ready.return_value = None
        entry = templates.selection(templates.BY_ID['reviewer'], 'capability', templates.catalog(cli, self.projects, str(self.projects)))
        self.assertEqual((entry['runtime'], entry['provider'], entry['model'], entry['reasoning']), ('agy', '', '', ''))
        self.assertEqual(launch_arguments(entry), [])


if __name__ == '__main__':
    unittest.main()
