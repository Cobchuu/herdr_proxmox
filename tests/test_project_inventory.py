"""Bounded project inventory: what a repository contains, before what it needs.

The census is the first thing every later tier reads, so these tests hold two
properties: it recognises a project nobody described in advance, and it never
claims a complete answer when a budget stopped it short.
"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import project_inventory


def tree(root, files):
    for name in files:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('', encoding='utf-8')
    return root


def languages(result):
    return [entry['id'] for entry in result['languages']]


class RecognitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_a_react_workspace_is_read_from_its_files_alone(self):
        tree(self.root, ['package.json', 'package-lock.json', 'tsconfig.json',
                         'vite.config.ts', 'src/main.tsx', 'src/App.tsx',
                         'src/components/Button.jsx', 'public/index.html'])
        result = project_inventory.scan(self.root)
        # Source first, and configuration is not a language: counting
        # package.json as "JSON" would rank it above the code it describes.
        self.assertEqual(languages(result)[0], 'typescript')
        self.assertIn('javascript', languages(result))
        self.assertNotIn('json', languages(result))
        self.assertIn('package.json', result['manifests'])
        self.assertIn('package-lock.json', result['manifests'])
        self.assertIn('tsconfig.json', result['manifests'])
        self.assertFalse(result['truncated'])

    def test_a_php_project_with_no_manifest_is_still_recognised(self):
        # The case that started this: index.php and no composer.json at all.
        tree(self.root, ['index.php', 'classes/User.php', 'template/header.php'])
        result = project_inventory.scan(self.root)
        self.assertEqual(languages(result), ['php'])
        self.assertEqual(result['manifests'], [])
        self.assertEqual(result['languages'][0]['evidence'][0], 'classes/User.php')

    def test_a_make_only_project_is_recognised_by_filename(self):
        tree(self.root, ['Makefile', 'src/main.c', 'src/generated.c.bak'])
        result = project_inventory.scan(self.root)
        self.assertIn('make', languages(result))
        self.assertIn('c', languages(result))

    def test_a_manifest_free_project_reports_no_languages_rather_than_guessing(self):
        tree(self.root, ['README', 'LICENSE', 'data.csv'])
        result = project_inventory.scan(self.root)
        self.assertEqual(result['languages'], [])
        self.assertEqual(result['files'], 3)

    def test_filenames_win_over_extensions(self):
        tree(self.root, ['CMakeLists.txt', 'Dockerfile', 'notes.txt'])
        result = project_inventory.scan(self.root)
        self.assertIn('cmake', languages(result))
        self.assertIn('dockerfile', languages(result))

    def test_several_languages_are_kept_separate_and_ordered_by_weight(self):
        tree(self.root, ['app.py', 'lib/a.py', 'lib/b.py', 'assets/site.css'])
        result = project_inventory.scan(self.root)
        self.assertEqual(languages(result), ['python', 'css'])
        self.assertEqual(result['languages'][0]['files'], 3)

    def test_component_manifests_keep_their_paths(self):
        tree(self.root, ['package.json', 'web/package.json', 'api/package.json'])
        result = project_inventory.scan(self.root)
        self.assertEqual(result['manifests'],
                         ['api/package.json', 'package.json', 'web/package.json'])

    def test_dependency_trees_and_build_output_do_not_dominate_the_census(self):
        tree(self.root, ['package.json', 'src/App.tsx',
                         'node_modules/react/index.js', 'node_modules/left-pad/index.js',
                         'node_modules/.bin/cli', 'dist/bundle.js', 'vendor/lib.go',
                         'build/out.o', '.git/config'])
        result = project_inventory.scan(self.root)
        self.assertEqual(languages(result), ['typescript'])
        self.assertEqual(result['manifests'], ['package.json'])
        for ignored in ('node_modules', 'dist', 'vendor', 'build', '.git'):
            self.assertEqual(result['skipped'].get(ignored), 1, ignored)

    def test_hidden_directories_are_scanned_because_declarations_live_there(self):
        tree(self.root, ['.github/workflows/ci.yml', '.nvmrc'])
        result = project_inventory.scan(self.root)
        self.assertIn('.nvmrc', result['manifests'])
        self.assertIn('yaml', languages(result))

    def test_an_absent_directory_is_an_empty_census_not_an_error(self):
        result = project_inventory.scan(self.root / 'missing')
        self.assertEqual((result['files'], result['languages'], result['manifests']), (0, [], []))
        self.assertFalse(result['truncated'])

    def test_found_but_understood_nothing_is_distinguishable_from_empty(self):
        # "No languages found" and "found files, understood none" are different
        # answers, and only one of them is a reason to stop looking.
        tree(self.root, ['data.bin', 'notes.custom', 'archive.xyz'])
        result = project_inventory.scan(self.root)
        self.assertEqual(result['languages'], [])
        self.assertEqual(result['unknown'], 3)
        self.assertEqual(result['files'], 3)
        self.assertEqual(sorted(result['unknown_evidence']),
                         ['archive.xyz', 'data.bin', 'notes.custom'])


class UncertaintyTests(unittest.TestCase):
    """Ambiguous, generated and vendored evidence is reported, never guessed."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_a_shared_extension_is_reported_ambiguous_not_guessed(self):
        # `.m` is MATLAB or Objective-C, and those need different toolchains.
        tree(self.root, ['solver.m', 'analysis.m'])
        result = project_inventory.scan(self.root)
        self.assertEqual(result['languages'], [])
        self.assertEqual(len(result['ambiguous']), 1)
        self.assertEqual(result['ambiguous'][0]['candidates'], ['matlab', 'objectivec'])
        self.assertEqual(result['ambiguous'][0]['files'], 2)
        self.assertEqual(result['unknown'], 0)

    def test_a_sibling_resolves_the_ambiguity_from_evidence(self):
        tree(self.root, ['main.m', 'Helper.mm', 'Podfile'])
        self.assertEqual(languages(project_inventory.scan(self.root)), ['objectivec'])
        tree(self.root / 'other', ['model.m', 'plot.mlx'])
        result = project_inventory.scan(self.root)
        self.assertEqual(sorted(languages(result)), ['matlab', 'objectivec'])
        self.assertEqual(result['ambiguous'], [])

    def test_headers_resolve_against_their_translation_units(self):
        tree(self.root, ['src/util.h', 'src/util.c'])
        self.assertEqual(languages(project_inventory.scan(self.root)), ['c'])
        alone = self.root / 'alone'
        tree(alone, ['api.h'])
        result = project_inventory.scan(alone)
        self.assertEqual(result['languages'], [])
        self.assertEqual(result['ambiguous'][0]['candidates'], ['c', 'cpp', 'objectivec'])

    def test_indicators_that_disagree_leave_the_extension_ambiguous(self):
        # A `.c` and a `.cpp` in one tree imply different languages for `.h`.
        # Picking one because of dictionary order would be a silent choice.
        tree(self.root, ['impl/a.c', 'impl/b.cpp', 'include/api.h'])
        result = project_inventory.scan(self.root)
        self.assertEqual(sorted(languages(result)), ['c', 'cpp'])
        self.assertEqual(result['ambiguous'][0]['candidates'], ['c', 'cpp'])
        self.assertEqual(result['ambiguous'][0]['evidence'], ['include/api.h'])

    def test_a_local_indicator_outranks_a_distant_one(self):
        # An Objective-C implementation beside the header settles it, even when
        # unrelated C source exists elsewhere in the tree.
        tree(self.root, ['shared.h', 'objc/App.mm', 'objc/App.h', 'native/core.c'])
        result = project_inventory.scan(self.root)
        self.assertIn('objectivec', languages(result))
        self.assertIn('c', languages(result))
        self.assertEqual([entry['evidence'] for entry in result['ambiguous']],
                         [['shared.h']])

    def test_generated_output_does_not_count_as_authored_source(self):
        tree(self.root, ['main.go', 'api.pb.go', 'api_grpc.pb.go', 'web/app.min.js'])
        result = project_inventory.scan(self.root)
        self.assertEqual(languages(result), ['go'])
        self.assertEqual(result['languages'][0]['files'], 1)
        self.assertEqual(result['generated'], 3)

    def test_vendor_and_generated_are_reported_separately(self):
        tree(self.root, ['app.py', 'vendor/lib.rb', 'dist/bundle.min.css'])
        result = project_inventory.scan(self.root)
        self.assertEqual(languages(result), ['python'])
        self.assertEqual(result['skipped'].get('vendor'), 1)
        self.assertEqual(result['skipped'].get('dist'), 1)
        self.assertEqual(result['ambiguous'], [])


    def test_a_directory_cap_does_not_abandon_its_siblings(self):
        # Truncation is a report about the answer, not a reason to stop walking:
        # one oversized directory must not cost the sibling its manifest.
        tree(self.root, [f'bulk/f{index}.php' for index in range(30)])
        tree(self.root, ['package.json'])
        with patch.object(project_inventory, 'MAX_PER_DIRECTORY', 10):
            result = project_inventory.scan(self.root, include_paths=True)
        self.assertTrue(result['truncated'])
        self.assertEqual(result['capped_directories'], 1)
        self.assertIn('package.json', result['manifests'])
        self.assertEqual(result['files'], 11)

    def test_a_clean_scan_reports_no_capped_directories(self):
        tree(self.root, ['a.php', 'b.php'])
        self.assertEqual(project_inventory.scan(self.root)['capped_directories'], 0)


class BoundTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_a_path_budget_stops_the_walk_and_says_so(self):
        tree(self.root, [f'src/file{i}.php' for i in range(40)])
        result = project_inventory.scan(self.root, {'max_paths': 10})
        self.assertTrue(result['truncated'])
        self.assertEqual(result['files'], 10)

    def test_a_complete_scan_is_not_marked_partial(self):
        tree(self.root, [f'src/file{i}.php' for i in range(20)])
        result = project_inventory.scan(self.root, {'max_paths': 100})
        self.assertFalse(result['truncated'])
        self.assertEqual(result['files'], 20)

    def test_a_time_budget_stops_the_walk(self):
        tree(self.root, [f'src/file{i}.js' for i in range(20)])
        result = project_inventory.scan(self.root, {'max_seconds': -1})
        self.assertTrue(result['truncated'])

    def test_deep_nesting_is_bounded(self):
        deep = '/'.join(f'd{index}' for index in range(project_inventory.MAX_DEPTH + 5))
        tree(self.root, [f'{deep}/leaf.js'])
        result = project_inventory.scan(self.root)
        self.assertTrue(result['truncated'])
        self.assertNotIn('javascript', languages(result))

    def test_the_scan_is_deterministic(self):
        tree(self.root, ['a.php', 'b.php', 'c.js', 'z/y.rb'])
        self.assertEqual(project_inventory.scan(self.root), project_inventory.scan(self.root))

    def test_a_symlink_is_counted_and_never_followed(self):
        outside = self.root / 'outside'
        tree(outside, ['secret.php'])
        project = self.root / 'project'
        tree(project, ['real.php'])
        try:
            (project / 'link.php').symlink_to(outside / 'secret.php')
            (project / 'linked').symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest('symlinks are not permitted for this user')
        result = project_inventory.scan(project)
        self.assertEqual(result['files'], 1)
        self.assertEqual(result['languages'][0]['evidence'], ['real.php'])
        self.assertEqual(result['skipped'].get('symlink'), 2)


if __name__ == '__main__':
    unittest.main()
