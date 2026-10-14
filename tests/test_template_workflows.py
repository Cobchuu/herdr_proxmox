from contextlib import closing
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
from organizations import OrganizationStore
from integration_coordinator import IntegrationCoordinator
from contributions import Contributions
import model_catalog
import template_workflows


class TemplateWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.projects = self.root / 'projects'
        self.repo = self.projects / 'repo'
        self.repo.mkdir(parents=True)
        self.git('init', '-b', 'main')
        (self.repo / 'file').write_text('base')
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-m', 'base')
        self.git('remote', 'add', 'origin', 'https://github.com/owner/repo.git')
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        self.command = Mock(side_effect=AssertionError('No startup prompts'))
        self.store = OrganizationStore(self.root / 'org.sqlite3', self.projects, self.command,
            template_catalog=lambda project: {'runtimes': {'claude': model_catalog.curated('claude')}})
        self.addCleanup(self.store.close)
        self.body = dict(request_id='workflow-team', name='Team', purpose='Build', project=str(self.repo),
            template_roles=['lead_developer', 'backend_developer', 'reviewer', 'qa_engineer', 'integration_engineer'])
        self.org = self.store.action('save', self.body)['id']
        self.profiles = {p['template_role']: p for p in self.store.profile_records()}

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def test_defaults_materialize_without_launch_and_preserve_manual_settings(self):
        coordinator = IntegrationCoordinator(self.root / 'integration.sqlite3', self.store)
        self.addCleanup(coordinator.close)
        settings = coordinator.configuration_records()
        self.assertEqual(len(settings), 1)
        self.assertEqual(settings[0]['profile_id'], self.profiles['integration_engineer']['id'])
        self.assertEqual(settings[0]['repository'], 'repo')
        self.assertFalse(settings[0]['auto_build'])
        self.assertFalse(settings[0]['auto_sdk'])
        coordinator.configure(dict(repository='repo', enabled=False))
        self.assertFalse(coordinator.configuration_records()[0]['enabled'])
        self.assertEqual(coordinator.configuration_records()[0]['profile_id'], self.profiles['integration_engineer']['id'])
        self.command.assert_not_called()
        restored = IntegrationCoordinator(self.root / 'restored.sqlite3', self.store)
        self.addCleanup(restored.close)
        self.assertEqual(restored.configuration_records()[0]['profile_id'], self.profiles['integration_engineer']['id'])

    def test_new_tasks_inherit_independent_review_and_qa_fallback(self):
        api = Mock()
        api.settings.return_value = {}
        api.status.return_value = {}
        tasks = Contributions(self.root / 'tasks.sqlite3', self.projects, self.store, api)
        self.addCleanup(tasks.close)
        for role, expected in [('backend_developer', 'reviewer'), ('reviewer', 'qa_engineer')]:
            task = tasks.action('create', dict(request_id='task-' + role, title='Task', description='Build feature',
                repository='repo', profile_id=self.profiles[role]['id']), 'admin', 'admin')
            self.assertEqual(task['acceptance']['reviewer_profile_id'], self.profiles[expected]['id'])
            self.assertTrue(task['acceptance']['auto'])
            self.assertFalse(task['auto_publish'])
        self.command.assert_not_called()

    def test_removed_or_foreign_reviewers_and_coordinators_are_ignored(self):
        org = self.store.organization_records()[0]
        profiles = list(self.profiles.values())
        for profile in profiles:
            if profile['template_role'] in ('reviewer', 'qa_engineer'):
                profile['removed_at'] = 'now'
        self.assertIsNone(template_workflows.acceptance(self.store, self.org, self.repo,
                         self.profiles['backend_developer']['id'], profiles))
        org['team_workflows']['coordinator_id'] = ['malformed']
        with self.store.lock, closing(self.store.connect()) as db, db:
            self.store.put(db, 'organizations', org)
        self.assertEqual(template_workflows.coordinator_configurations(self.store), [])

    def test_workflow_defaults_survive_edits_and_request_replays(self):
        original = self.store.organization_records()[0]['team_workflows']
        self.assertEqual(self.store.action('save', self.body)['id'], self.org)
        self.store.action('save', dict(request_id='workflow-edit', id=self.org, name='Renamed', purpose='Build'))
        self.assertEqual(self.store.organization_records()[0]['team_workflows'], original)
        self.assertEqual(len(self.store.profile_records()), 5)


if __name__ == '__main__':
    unittest.main()
