"""The Linux gate must reject incomplete evidence, even when unittest passes."""
from contextlib import nullcontext, redirect_stderr
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/test-project-discovery.py'
SPEC = importlib.util.spec_from_file_location('discovery_test_runner', SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class DiscoveryTestRunnerTests(unittest.TestCase):
    def run_gate(self, test):
        output = io.StringIO()
        with redirect_stderr(output):
            status = runner.run_suite(unittest.TestSuite([test]))
        return status, output.getvalue()

    def test_success_is_accepted(self):
        status, _ = self.run_gate(unittest.FunctionTestCase(lambda: None))
        self.assertEqual(status, 0)

    def test_skip_is_failure_even_when_unittest_succeeds(self):
        def skipped():
            raise unittest.SkipTest('native prerequisite missing')
        status, output = self.run_gate(unittest.FunctionTestCase(skipped))
        self.assertEqual(status, 1)
        self.assertIn('NOT VERIFIED', output)
        self.assertIn('native prerequisite missing', output)

    def test_failed_subtest_is_failure(self):
        class FailingSubtest(unittest.TestCase):
            def runTest(self):
                with self.subTest(boundary='ancestor'):
                    self.fail('escaped')
        status, _ = self.run_gate(FailingSubtest())
        self.assertEqual(status, 1)

    def test_import_failure_is_failure(self):
        suite = unittest.TestLoader().loadTestsFromName('nonexistent_herdr_boundary_test')
        with redirect_stderr(io.StringIO()):
            self.assertEqual(runner.run_suite(suite), 1)

    def test_empty_suite_is_failure(self):
        output = io.StringIO()
        with redirect_stderr(output):
            self.assertEqual(runner.run_suite(unittest.TestSuite()), 1)
        self.assertIn('no tests were discovered', output.getvalue())

    def test_all_discovers_unlisted_module_and_rejects_its_skip(self):
        name = 'test_new_unlisted_herdr_boundary'
        self.assertNotIn(name, runner.MODULES)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            tests = root / 'tests'
            tests.mkdir()
            (tests / f'{name}.py').write_text(
                'import unittest\n'
                'class BoundaryTest(unittest.TestCase):\n'
                '    @unittest.skip("new boundary unavailable")\n'
                '    def test_boundary(self): pass\n', encoding='utf-8')
            with patch.object(sys, 'path', sys.path.copy()), patch.dict(sys.modules):
                suite = runner.load_suite(all_tests=True, root=root)
                self.assertEqual(suite.countTestCases(), 1)
                output = io.StringIO()
                with redirect_stderr(output):
                    self.assertEqual(runner.run_suite(suite), 1)
                self.assertIn('new boundary unavailable', output.getvalue())

    def test_all_option_routes_to_discovery_after_preflight(self):
        # This checks CLI routing only; the real native preflight remains in the
        # Linux CI run and is never substituted to claim boundary verification.
        with patch.object(runner, 'preflight') as preflight, \
                patch.object(runner, 'load_suite') as load, \
                patch.object(runner, 'run_suite', return_value=1) as run:
            self.assertEqual(runner.main(['--all']), 1)
        preflight.assert_called_once_with()
        load.assert_called_once_with(True)
        run.assert_called_once_with(load.return_value, False)

    def test_skill_markdown_changes_fingerprint(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'scripts/test-project-discovery.py'
            script.parent.mkdir()
            script.write_text('# runner\n', encoding='utf-8')
            reference = root / 'web/gateway/skills/integration/references/merge.md'
            reference.parent.mkdir(parents=True)
            before = runner.source_fingerprint(root)
            reference.write_text('first guidance\n', encoding='utf-8')
            added = runner.source_fingerprint(root)
            reference.write_text('changed guidance\n', encoding='utf-8')
            changed = runner.source_fingerprint(root)
            self.assertNotEqual(before, added)
            self.assertNotEqual(added, changed)
            self.assertEqual(changed, runner.source_fingerprint(root))

    def test_symlink_probe_requires_expected_rejection(self):
        expected = Mock(side_effect=ValueError('Project path is unavailable or contains a symbolic link.'))
        runner.require_symlink_rejection(expected, Path('project'))
        unrelated = Mock(side_effect=ValueError('Select a relative path inside the project.'))
        with self.assertRaisesRegex(RuntimeError, 'Unexpected ancestor-symlink rejection'):
            runner.require_symlink_rejection(unrelated, Path('project'))
        with self.assertRaisesRegex(RuntimeError, 'An ancestor symlink was followed'):
            runner.require_symlink_rejection(lambda *args: nullcontext(), Path('project'))


if __name__ == '__main__':
    unittest.main()
