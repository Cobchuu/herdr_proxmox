"""SDK lookup context, nearest-file shadowing and explicit repository boundary."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
from project_inventory import from_paths
from project_requirements import analyse


def report(files, context=None):
    return analyse(Path('.'), inventory=from_paths(files),
                   read=lambda name, limit: files[name].encode()[:limit + 1], lookup_context=context)


def sdk(result, path='Api'):
    return next(c for c in result['components'] if c['path'] == path)['requirements'][0]


class DotnetResolutionTests(unittest.TestCase):
    def test_component_inherits_nearest_ancestor_with_evidence(self):
        selected = sdk(report({'global.json': '{"sdk":{"version":"8.0.100"}}', 'Api/App.csproj': ''}))
        self.assertEqual(selected['selected'], '8.0.100')
        self.assertEqual(selected['observations'][0]['file'], 'global.json')
        self.assertTrue(selected['resolution']['inherited'])
        self.assertEqual(selected['resolution']['context']['directory'], 'Api')
        self.assertEqual(selected['resolution']['boundary'], 'repository root')

    def test_nearest_file_shadows_parent_without_conflicting(self):
        selected = sdk(report({'global.json': '{"sdk":{"version":"8.0.100"}}',
                               'Api/global.json': '{"sdk":{"version":"9.0.200"}}', 'Api/App.csproj': ''}))
        self.assertEqual(selected['selected'], '9.0.200')
        self.assertEqual(selected['conflicts'], [])
        self.assertEqual(selected['resolution']['shadowed'], ['global.json'])

    def test_malformed_or_missing_version_does_not_fall_back(self):
        for local in ('not json', '{}', '{"sdk":{"rollForward":"latestMajor"}}'):
            with self.subTest(local=local):
                selected = sdk(report({'global.json': '{"sdk":{"version":"8.0.100"}}',
                                       'Api/global.json': local, 'Api/App.csproj': ''}))
                self.assertFalse(selected['established'])
                self.assertEqual(selected['selected'], '')
                self.assertEqual(selected['resolution']['evidence'], 'Api/global.json')
                self.assertEqual(selected['resolution']['shadowed'], ['global.json'])

    def test_explicit_cli_directory_can_differ_from_component(self):
        selected = sdk(report({'global.json': '{"sdk":{"version":"8.0.100"}}',
                               'Api/global.json': '{"sdk":{"version":"9.0.200"}}', 'Api/App.csproj': ''}, '.'))
        self.assertEqual(selected['selected'], '8.0.100')
        self.assertEqual(selected['resolution']['context']['kind'], 'cli_directory')

    def test_policies_are_preserved_without_claiming_host_selection(self):
        policy = {'version': '8.0.100', 'rollForward': 'latestFeature', 'allowPrerelease': False}
        selected = sdk(report({'global.json': json.dumps({'sdk': policy}), 'Api/App.csproj': ''}))
        self.assertEqual(selected['resolution']['policies'], {'rollForward': 'latestFeature', 'allowPrerelease': False})
        self.assertEqual(selected['resolution']['assessment'], 'unresolved')

    def test_lookup_stops_at_repository_boundary(self):
        selected = sdk(report({'Api/App.csproj': ''}))
        self.assertEqual(selected['resolution']['searched'], ['Api/global.json', 'global.json'])
        self.assertFalse(selected['established'])
        for context in ('..', '/outside', 'C:/outside', 'Api\\outside'):
            with self.subTest(context=context), self.assertRaises(ValueError):
                report({'Api/App.csproj': ''}, context)
