"""Real descriptor races at the shared browsing/discovery boundary."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import project_access
import project_inventory
from project_requirements import manifest_reader


class PathValidationTests(unittest.TestCase):
    def test_escaping_and_alternate_path_forms_are_refused(self):
        for value in ('/outside/package.json', '../package.json', 'x/../package.json',
                      'C:/package.json', 'x\\package.json', 'x\x00.json'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                project_access.relative_path(value)

    def test_unsupported_platform_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(project_access, 'ANCHORED_ACCESS', False):
                with self.assertRaises(ValueError):
                    project_inventory.scan(folder)
                self.assertIsNone(manifest_reader(folder)('package.json'))


@unittest.skipUnless(project_access.ANCHORED_ACCESS, 'Native descriptor access required')
class DescriptorRaceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / 'project'
        self.nested = self.root / 'nested'
        self.nested.mkdir(parents=True)
        self.outside = self.base / 'outside'
        self.outside.mkdir()
        (self.nested / 'package.json').write_text('inside', encoding='utf-8')
        (self.outside / 'package.json').write_text('outside', encoding='utf-8')
        (self.outside / 'secret.php').write_text('outside', encoding='utf-8')

    def swap(self):
        self.nested.rename(self.root / 'previous')
        self.nested.symlink_to(self.outside, target_is_directory=True)

    def test_manifest_ancestor_replacement_before_open_is_refused(self):
        project_inventory.scan(self.root)  # The directory was legitimate at census time.
        self.swap()
        self.assertIsNone(manifest_reader(self.root)('nested/package.json'))

    def test_manifest_ancestor_replacement_after_open_keeps_original_directory(self):
        original = os.open
        opened = []
        def race(path, flags, **kwargs):
            descriptor = original(path, flags, **kwargs)
            opened.append(descriptor)
            if str(path) == 'nested':
                self.swap()
            return descriptor
        with patch('project_access.os.open', side_effect=race):
            self.assertEqual(manifest_reader(self.root)('nested/package.json'), b'inside')
        for descriptor in opened:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_census_directory_replacement_before_open_is_not_followed(self):
        original = os.open
        def race(path, flags, **kwargs):
            if str(path) == 'nested':
                self.swap()
            return original(path, flags, **kwargs)
        with patch('project_access.os.open', side_effect=race):
            report = project_inventory.scan(self.root, include_paths=True)
        self.assertNotIn('nested/secret.php', report['paths'])
        self.assertEqual(report['skipped']['unreadable'], 1)

    def test_census_directory_replacement_after_open_keeps_original_directory(self):
        original = os.open
        def race(path, flags, **kwargs):
            descriptor = original(path, flags, **kwargs)
            if str(path) == 'nested':
                self.swap()
            return descriptor
        with patch('project_access.os.open', side_effect=race):
            report = project_inventory.scan(self.root, include_paths=True)
        self.assertEqual(report['paths'], ['nested/package.json'])

    def test_root_and_final_symlinks_are_refused(self):
        (self.root / 'link.json').symlink_to(self.outside / 'package.json')
        self.assertIsNone(manifest_reader(self.root)('link.json'))
        self.root.rename(self.base / 'previous')
        self.root.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            project_inventory.scan(self.root)
        self.assertIsNone(manifest_reader(self.root)('package.json'))

    def test_production_entry_point_does_not_canonicalize_a_swapped_root(self):
        from project_analysis import ProjectAnalysis
        service = ProjectAnalysis(self.root)
        self.root.rename(self.base / 'previous')
        self.root.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(ValueError):
            service.report('outside', force=True)

    def test_regular_file_and_byte_limits_are_preserved(self):
        reader = manifest_reader(self.root)
        self.assertEqual(reader('nested/package.json', 3), b'insi')
        self.assertIsNone(reader('nested'))
        os.mkfifo(self.root / 'fifo.json')
        self.assertIsNone(reader('fifo.json'))
