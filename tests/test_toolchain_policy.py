"""Toolchain approval, probing and immutable validation rules."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'web/gateway'))
import toolchain_policy as policy


class ToolchainPolicyTests(unittest.TestCase):
    def test_bundled_dart_is_probed_against_the_flutter_report(self):
        with tempfile.TemporaryDirectory() as directory:
            flutter, dart = (Path(directory) / name for name in ('flutter', 'dart'))
            for executable in (flutter, dart):
                executable.write_text('fixture')
            selected = {'toolchains': [{'name': 'flutter', 'required': '1.2.3',
                                       'executables': [str(flutter), str(dart)]}]}
            runner = Mock(side_effect=[
                Mock(returncode=0, stdout='{"frameworkVersion":"1.2.3","dartSdkVersion":"3.4.5"}', stderr=''),
                Mock(returncode=0, stdout='', stderr='Dart SDK version: 3.9.0')])
            evidence = policy.verify(selected, run=runner)
            self.assertTrue(evidence[0]['matches'])
            self.assertFalse(evidence[1]['matches'])
            self.assertEqual(evidence[1]['required'], '3.4.5')

    def test_failed_or_malformed_probe_cannot_certify_the_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'flutter'
            executable.write_text('fixture')
            for output, code in ((json.dumps({'frameworkVersion': '1.2.3'}), 1), ('[]', 0), ('null', 0)):
                runner = Mock(return_value=Mock(returncode=code, stdout=output, stderr=''))
                self.assertFalse(policy.probe('flutter', str(executable), '1.2.3', run=runner)['matches'])

    def test_present_but_invalid_declaration_cannot_disable_the_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / 'catalog.json'
            catalog.write_text(json.dumps({'flutter': {'version_source': {'file': '.fvmrc', 'key': 'flutter'}}}))
            for content in ('{}', '{broken', '{"flutter":"latest"}'):
                (root / '.fvmrc').write_text(content)
                with self.assertRaisesRegex(ValueError, 'declaration is invalid'):
                    policy.resolve(root, catalog)

    def test_a_malformed_catalog_is_not_a_toolchain_free_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / 'catalog.json'
            for content in ('{broken', '[]', '{"flutter":"broken"}'):
                catalog.write_text(content)
                with self.assertRaises(ValueError):
                    policy.resolve(root, catalog)

    def test_environment_uses_the_platform_path_separator(self):
        selected = {'toolchains': [{'executables': [str(Path('/sdk/bin/flutter'))]}]}
        value = policy.environment(selected, {'PATH': 'existing', 'KEEP': 'value'})
        self.assertEqual(value['PATH'], str(Path('/sdk/bin')) + os.pathsep + 'existing')
        self.assertEqual(value['KEEP'], 'value')
