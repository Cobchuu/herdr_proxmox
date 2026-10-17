"""Assisted results are claims until their allocated bytes have been adopted."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import environment_adapters
import environment_adoption as adoption
import environment_artifacts
import environment_plan
import toolchain_policy
from project_access import ANCHORED_ACCESS


class AdapterTests(unittest.TestCase):
    def test_activation_and_command_knowledge_comes_from_one_registry(self):
        self.assertEqual(environment_adapters.managed(), ('python', 'dotnet-sdk', 'rust-toolchain'))
        self.assertEqual(environment_adapters.commands()['npm'], 'node')
        self.assertIsNone(environment_adapters.get('node').resolver)
        self.assertEqual(environment_adapters.get('dotnet-sdk').environment('/sdk/dotnet')['DOTNET_ROOT'], str(Path('/sdk')))
        with self.assertRaises(ValueError):
            environment_adapters.get('node').command('/sdk/bin/node', 'bash')


@unittest.skipUnless(ANCHORED_ACCESS and sys.platform == 'linux', 'Requires native anchored Linux SDK access.')
class AdoptionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.allocation = self.root / 'allocation'
        self.sdk = self.allocation / 'sdk-0'
        (self.sdk / 'bin').mkdir(parents=True)
        for name, output in (('node', 'v20.19.0'), ('npm', '10.8.0')):
            executable = self.sdk / 'bin' / name
            executable.write_text('#!/bin/sh\necho ' + output + '\n')
            executable.chmod(0o755)
        self.plan = dict(project='app', revision='a' * 40, requirements=[dict(tool='node', capability='node',
            label='Node.js', components=['.'], version='', notation='semver', constraint='>=20 <23', state='unsupported',
            evidence=[dict(constraint='>=20 <23', notation='semver')], preparation_method='agent',
            activation='awaiting_adoption')], selected_checks=[])
        self.plan['digest'] = environment_plan.digest(self.plan)
        self.result = dict(plan_digest=self.plan['digest'], tools=[dict(index=0,
            provenance=dict(source='https://example.invalid/node', method='fixture installation'))])

    def adopt(self):
        return adoption.adopt(self.plan, self.result, self.allocation, self.root / 'store', {'actor': 'admin'})

    def test_adoption_is_new_identity_with_independent_version_and_content_evidence(self):
        original = copy.deepcopy(self.plan)
        adopted = self.adopt()
        self.assertEqual(self.plan, original)
        self.assertNotEqual(adopted['digest'], original['digest'])
        item = adopted['requirements'][0]
        self.assertEqual(item['version'], '20.19.0')
        self.assertEqual(item['artifact']['provenance']['verification'], 'agent_claim')
        receipt = adoption.receipt(item['artifact'], self.root / 'store')
        self.assertEqual(receipt['probe']['npm_version'], '10.8.0')
        self.assertNotEqual(receipt['probe']['executable'], str(self.sdk / 'bin/node'))
        bound = environment_plan.bindings(adopted, dict(state='ready', digest=adopted['digest'],
            revision=adopted['revision'], receipts=[dict(capability='node', version='20.19.0', components=['.'], **receipt)]))
        self.assertEqual(bound['toolchains'][0]['companions'][0]['name'], 'npm')
        self.assertTrue(all(item['matches'] for item in toolchain_policy.verify(bound, root=self.allocation)))
        (Path(item['artifact']['prefix']) / 'bin/node').write_text('#!/bin/sh\necho v20.19.0\n# changed\n')
        with self.assertRaisesRegex(ValueError, 'contents changed'):
            adoption.receipt(item['artifact'], self.root / 'store')
        self.assertFalse(toolchain_policy.verify(bound, root=self.allocation)[0]['matches'])

    def test_a_reported_version_never_overrides_the_binary_or_constraint(self):
        self.result['tools'][0]['version'] = '20.19.0'
        (self.sdk / 'bin/node').write_text('#!/bin/sh\necho v19.0.0\n')
        with self.assertRaisesRegex(ValueError, 'every recorded'):
            self.adopt()

    def test_links_in_the_sdk_or_its_ancestors_are_refused(self):
        (self.sdk / 'link').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'regular files'):
            self.adopt()
        (self.sdk / 'link').unlink()
        self.sdk.rename(self.allocation / 'original')
        self.sdk.symlink_to(self.allocation / 'original', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symbolic link'):
            self.adopt()

    def test_plan_identity_duplicate_results_and_provenance_are_validated(self):
        for change in (dict(plan_digest='b' * 64), dict(tools=self.result['tools'] * 2),
                       dict(tools=[dict(index=0, provenance=dict(source='file:///tmp/sdk', method='copy'))])):
            with self.subTest(change=change), self.assertRaises(ValueError):
                adoption.adopt(self.plan, dict(self.result, **change), self.allocation, self.root / 'store', {})

    def test_budgets_and_probe_side_effects_fail_without_publishing(self):
        with patch.object(adoption, 'MAX_BYTES', 1), self.assertRaisesRegex(ValueError, 'byte budget'):
            self.adopt()
        executable = self.sdk / 'bin/node'
        executable.write_text('#!/bin/sh\necho touched > "$(dirname "$0")/touched"\necho v20.19.0\n')
        with self.assertRaisesRegex(ValueError, 'probe modified'):
            self.adopt()
        self.assertFalse(any(path.name[0] != '.' for path in (self.root / 'store/adopted').iterdir()))

    def test_cancellation_and_wrong_store_cannot_adopt_or_reuse(self):
        with self.assertRaisesRegex(ValueError, 'cancelled'):
            adoption.adopt(self.plan, self.result, self.allocation, self.root / 'store', {}, cancelled=lambda: True)
        item = self.adopt()['requirements'][0]
        with self.assertRaisesRegex(ValueError, 'outside'):
            adoption.receipt(item['artifact'], self.root / 'another-store')
