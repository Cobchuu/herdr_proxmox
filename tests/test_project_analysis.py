"""The cached discovery entry point and the provenance it reports.

Discovery is expensive and the dashboard polls, so it is cached — but a cache
that cannot say what it knows is worse than no cache. These tests hold the two
scopes apart: a committed report is pinned to a revision, a working-tree report
has a window and says so.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
from project_analysis import ANALYZER_VERSION, ProjectAnalysis


def write(root, files):
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
    return root


def git(root, *arguments):
    """Run git, or None where the harness cannot spawn a process."""
    try:
        return subprocess.run(['git', '-C', str(root), *arguments], capture_output=True,
                              text=True, timeout=60)
    except OSError:
        return None


class ProjectAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.projects = Path(self.temp.name) / 'projects'
        write(self.projects, {'app/package.json': json.dumps({'engines': {'node': '>=20'}})})
        self.analysis = ProjectAnalysis(self.projects)

    def repo(self, name, files):
        """A real Git repository, so committed scope is exercised for real.

        Skipped where the harness cannot spawn git; on a Linux host these run.
        """
        root = self.projects / name
        write(root, files)
        if git(root, 'init', '-q') is None:
            self.skipTest('this harness cannot spawn git')
        git(root, 'config', 'user.email', 'test@example.invalid')
        git(root, 'config', 'user.name', 'Test')
        return root

    def commit(self, name):
        root = self.projects / name
        git(root, 'add', '-A')
        git(root, 'commit', '-q', '-m', 'fixture')
        return git(root, 'rev-parse', 'HEAD').stdout.strip()

    def test_a_working_tree_report_is_reused_within_its_window(self):
        first = self.analysis.report('app')
        second = self.analysis.report('app')
        self.assertIs(first, second)
        self.assertEqual(first['source']['scope'], 'working_tree')
        self.assertEqual(first['source']['analyzer'], ANALYZER_VERSION)

    def test_a_refresh_bypasses_the_window(self):
        self.analysis.report('app')
        write(self.projects, {'app/.nvmrc': '20.11.1\n'})
        cached = self.analysis.report('app')
        self.assertEqual(cached['components'][0]['requirements'][0]['selected'], '')
        refreshed = self.analysis.report('app', force=True)
        self.assertEqual(refreshed['components'][0]['requirements'][0]['selected'], '20.11.1')

    def test_a_committed_report_reads_the_commit_not_the_working_tree(self):
        self.repo('app', {'package.json': json.dumps({'engines': {'node': '>=20'}})})
        revision = self.commit('app')
        committed = self.analysis.report('app', revision=revision)
        self.assertEqual(committed['components'][0]['requirements'][0]['constraint'], '>=20')
        # An uncommitted edit must be invisible to the committed scope, and
        # visible to the working-tree scope.
        write(self.projects, {'app/package.json': json.dumps({'engines': {'node': '>=99'}})})
        again = self.analysis.report('app', revision=revision, force=True)
        self.assertEqual(again['components'][0]['requirements'][0]['constraint'], '>=20')
        self.assertEqual(
            self.analysis.report('app', force=True)['components'][0]['requirements'][0]['constraint'],
            '>=99')
        self.assertEqual(again['source']['scope'], 'committed')
        self.assertEqual(again['source']['revision'], revision)
        self.assertEqual(again['source']['boundary'], 'repository root')

    def test_a_committed_report_reads_files_absent_from_the_working_tree(self):
        self.repo('php', {'composer.json': json.dumps({'require': {'php': '^8.2'}})})
        revision = self.commit('php')
        (self.projects / 'php' / 'composer.json').unlink()
        committed = self.analysis.report('php', revision=revision)
        self.assertEqual(committed['components'][0]['requirements'][0]['constraint'], '^8.2')
        self.assertEqual(self.analysis.report('php', force=True)['components'], [])

    def test_a_revision_that_does_not_resolve_is_refused(self):
        # No repository needed: an unresolvable revision is refused either way,
        # and nothing is cached under a revision that was never verified.
        for revision in ('0' * 40, 'f' * 40, 'abc', 'a' * 39, 'A' * 40, 123):
            with self.assertRaises(ValueError):
                self.analysis.report('app', revision=revision)
        self.assertEqual(self.analysis.cache, {})

    def test_a_revision_is_refused_outside_a_repository(self):
        write(self.projects, {'plain/package.json': '{}'})
        with self.assertRaisesRegex(ValueError, 'does not exist in this project'):
            self.analysis.report('plain', revision='a' * 40)

    def test_a_committed_report_is_reused_and_a_different_revision_is_not(self):
        self.repo('app', {'package.json': json.dumps({'engines': {'node': '>=20'}})})
        first_revision = self.commit('app')
        first = self.analysis.report('app', revision=first_revision)
        self.assertIs(first, self.analysis.report('app', revision=first_revision))
        write(self.projects, {'app/extra.ts': ''})
        second_revision = self.commit('app')
        self.assertIsNot(first, self.analysis.report('app', revision=second_revision))

    def test_the_report_carries_the_evidence_the_page_displays(self):
        write(self.projects, {'app/src/main.ts': '', 'app/legacy/index.php': '<?php'})
        report = self.analysis.report('app', force=True)
        paths = [(item['path'], item['basis']) for item in report['components']]
        self.assertIn(('.', 'manifest'), paths)
        self.assertIn(('legacy', 'inferred'), paths)
        self.assertIn('coverage', report)
        self.assertEqual(report['coverage']['files'], 3)


class EffectiveReportTests(unittest.TestCase):
    """One resolved view shared by the card, readiness and provisioning."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.projects = Path(self.temp.name) / 'projects'
        write(self.projects, {'app/package.json': json.dumps({'engines': {'node': '>=20 <23'}}),
                              'app/index.php': '<?php'})
        self.overrides = {}
        self.analysis = ProjectAnalysis(
            self.projects, overrides=lambda: self.overrides,
            toolchains=lambda: {'node': {'required': '20.11.1', 'executable': ''},
                                'php': {'required': '8.2.7', 'executable': ''}},
            catalog=lambda: {'node': {}, 'php': {}})

    def effective(self, **kwargs):
        return self.analysis.effective('app', which=lambda name: '/usr/bin/' + name,
                                       run=fake_run('20.11.1'), **kwargs)

    def test_discovered_requirements_are_assessed_against_the_host(self):
        report = self.effective()
        tools = {entry['tool']: entry for entry in report['requirements']}
        self.assertEqual(tools['node']['constraint'], '>=20 <23')
        self.assertEqual(tools['node']['assessment']['verdict'], 'satisfied')
        self.assertEqual(tools['node']['assessment']['installer'], True)
        self.assertEqual(tools['node']['assessment']['provisionable'], True)
        # PHP is discovered from source but the release cannot install it.
        self.assertEqual(tools['php']['assessment']['installer'], True)
        self.assertTrue(tools['php']['assessment']['selected'])

    def test_an_override_supplements_and_is_reported_when_it_disagrees(self):
        self.overrides['app'] = dict(repository='app', origin='operator_override',
                                     toolchain='node', constraint='>=22', notation='semver',
                                     actor='admin', at='2026-01-01T00:00:00Z')
        report = self.effective()
        node = next(entry for entry in report['requirements'] if entry['tool'] == 'node')
        # The override is authoritative because a person decided it...
        self.assertEqual(node['constraint'], '>=22')
        self.assertEqual(node['override']['actor'], 'admin')
        # ...and the disagreement with the repository is recorded, not hidden.
        self.assertEqual([item['kind'] for item in node['conflicts']], ['override'])
        self.assertIn('the repository declares >=20 <23', node['conflicts'][0]['reason'])

    def test_an_override_that_agrees_is_not_a_conflict(self):
        self.overrides['app'] = dict(repository='app', origin='operator_override',
                                     toolchain='node', constraint='>=20 <23', notation='semver',
                                     actor='admin', at='2026-01-01T00:00:00Z')
        node = next(entry for entry in self.effective()['requirements'] if entry['tool'] == 'node')
        self.assertEqual(node['conflicts'], [])

    def test_an_override_adds_a_requirement_discovery_did_not_establish(self):
        write(self.projects, {'plain/data.bin': ''})
        self.overrides['plain'] = dict(repository='plain', origin='operator_override',
                                       toolchain='node', constraint='20.11.1', notation='semver',
                                       actor='admin', at='2026-01-01T00:00:00Z')
        report = self.analysis.effective('plain', which=lambda name: '/usr/bin/' + name,
                                         run=fake_run('20.11.1'))
        self.assertEqual([entry['tool'] for entry in report['requirements']], ['node'])
        self.assertEqual(report['requirements'][0]['override']['origin'], 'operator_override')

    def test_two_installable_requirements_are_refused_rather_than_chosen_between(self):
        report = self.effective()
        self.assertEqual(report['provisionable'], ['node', 'php'])
        self.assertIn('cannot choose one', report['project_requirement']['reason'])
        self.assertEqual(report['project_requirement']['source'], 'working_tree')

    def test_one_installable_requirement_is_unambiguous(self):
        write(self.projects, {'solo/package.json': json.dumps({'engines': {'node': '>=20'}})})
        report = self.analysis.effective('solo', which=lambda name: '/usr/bin/node',
                                         run=fake_run('20.11.1'))
        self.assertEqual(report['provisionable'], ['node'])
        self.assertEqual(report['project_requirement']['reason'], '')

    def test_nothing_installable_says_so(self):
        write(self.projects, {'bare/index.php': '<?php'})
        report = ProjectAnalysis(self.projects, overrides=lambda: {},
                                 toolchains=lambda: {}, catalog=lambda: {}).effective(
            'bare', which=lambda name: None, run=fake_run('8.2'))
        self.assertEqual(report['provisionable'], [])
        self.assertIn('No requirement of this project can be satisfied',
                      report['project_requirement']['reason'])

    def test_a_host_measurement_is_reused_and_a_refresh_measures_again(self):
        # The dashboard polls and the coordinator re-reads on every blocked
        # event; probing every executable on each pass is the same answer bought
        # repeatedly, with a process per requirement.
        import project_toolchains
        probe = Mock(return_value=Mock(returncode=0, stdout='tool 20.11.1\n', stderr=''))
        with patch.object(project_toolchains.shutil, 'which',
                          side_effect=lambda name: '/usr/bin/' + name), \
             patch.object(project_toolchains.subprocess, 'run', probe):
            first = self.analysis.effective('app')
            measured = probe.call_count
            self.assertGreater(measured, 0)
            self.assertEqual(first['requirements'][0]['assessment']['verdict'], 'satisfied')
            self.analysis.effective('app')
            self.assertEqual(probe.call_count, measured)
            self.analysis.effective('app', force=True)
            self.assertEqual(probe.call_count, measured * 2)

    def test_a_supplied_probe_is_never_served_from_the_cache(self):
        # A caller bringing its own `which`/`run` asks a different question than
        # the cached one, so its answer must not satisfy a later real read.
        import project_toolchains
        self.effective()
        probe = Mock(return_value=Mock(returncode=0, stdout='tool 20.11.1\n', stderr=''))
        with patch.object(project_toolchains.shutil, 'which',
                          side_effect=lambda name: '/usr/bin/' + name), \
             patch.object(project_toolchains.subprocess, 'run', probe):
            self.analysis.effective('app')
            self.assertGreater(probe.call_count, 0)


def fake_run(version, returncode=0):
    from unittest.mock import Mock
    return Mock(return_value=Mock(returncode=returncode, stdout=f'tool {version}\n', stderr=''))


if __name__ == '__main__':
    unittest.main()
