"""Actual launch admission, persistent PTYs, preparation and crash boundaries."""
from contextlib import closing
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import environment_plan
from environment_admission import EnvironmentAdmission
from organizations import OrganizationStore
import test_environment_guardrails as fixtures


@unittest.skipUnless(sys.platform == 'linux', 'Requires native Linux process/worktree execution.')
class AdmissionTests(unittest.TestCase):
    git = fixtures.GatewayPolicyTests.git
    commit = fixtures.GatewayPolicyTests.commit

    def setUp(self):
        fixtures.GatewayPolicyTests.setUp(self)
        self.socket = self.root / 'runtime.sock'
        self.runtime = Path(__file__).parent / 'ci/environment_daemon.py'
        self.daemon = subprocess.Popen([sys.executable, str(self.runtime), '--daemon', str(self.socket), str(self.root)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_runtime)
        deadline = time.monotonic() + 5
        while not self.socket.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(self.socket.exists())
        self.approval = dict(auto_prepare=True, auto_prepare_checks=True, auto_prepare_revision='first')
        self.create_store()
        from permissions import prepare_permissions
        grant = patch('organizations.prepare_permissions', side_effect=lambda profile, output, **kwargs:
                      prepare_permissions(profile, output, home=self.root / 'home', **kwargs))
        grant.start()
        self.addCleanup(grant.stop)
        self.org = self.store.action('save', dict(request_id='create-organization', name='Team', purpose='Test', instructions='Test'))['id']
        self.downloads = []
        acquire = self.service.acquire
        def tracked(*args, **kwargs):
            self.downloads.append(args[0])
            return acquire(*args, **kwargs)
        self.service.acquire = tracked

    def create_store(self):
        self.store = OrganizationStore(self.root / 'organizations.sqlite3', self.projects, self.command)
        self.addCleanup(self.store.close)
        self.store.contributions = SimpleNamespace(policy=lambda _: dict(self.approval))
        self.admission = EnvironmentAdmission(self.store, self.service)
        self.store.environment_admission = self.admission
        self.service.admission = self.admission

    def stop_runtime(self):
        if self.daemon.poll() is None:
            try:
                self.command('test', 'stop')
                self.daemon.wait(timeout=8)
            except (ValueError, subprocess.SubprocessError):
                self.daemon.kill()
                self.daemon.wait(timeout=5)
        errors = self.daemon.stderr.read().decode()
        self.daemon.stderr.close()
        self.assertEqual(self.daemon.returncode, 0, errors)

    def command(self, *arguments, **options):
        result = subprocess.run([sys.executable, str(self.runtime), str(self.socket), *arguments],
                                capture_output=True, text=True, timeout=options.get('timeout', 12))
        if result.returncode:
            raise ValueError(result.stderr)
        record = json.loads(result.stdout)
        if 'error' in record:
            raise ValueError(record['error'])
        return record['result']

    def calls(self):
        path = self.root / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def launch(self, name='Engineer'):
        import uuid
        profile = self.store.action('hire', dict(request_id=uuid.uuid4().hex, organization_id=self.org,
            name=name, role='Engineer', runtime='codex', persona='Test', project=str(self.repo), manager_id=''))['id']
        job = self.store.action('launch', dict(request_id=uuid.uuid4().hex,
            organization_id=self.org, profile_id=profile))['id']
        self.store.wait_idle()
        return job

    def row(self, identity):
        with closing(self.store.connect()) as db:
            return self.store.get(db, 'jobs', identity)

    def finish(self):
        self.admission.tick()
        self.service.tick()
        self.admission.tick()
        self.store.wait_idle(timeout=20)

    def test_launch_parks_without_a_pane_then_inherits_the_prepared_sdk(self):
        identity = self.launch()
        self.assertEqual(self.row(identity)['state'], 'waiting_environment')
        self.assertEqual(self.calls(), [])
        self.finish()
        job = self.row(identity)
        self.assertEqual(job['state'], 'persona_sent', job.get('error'))
        self.assertEqual(job['environment_binding']['state'], 'inherited')
        self.assertEqual(len(self.downloads), 1)
        self.assertEqual(self.service.store.waiter(identity)['state'], 'resumed')
        second = self.launch('Another engineer')
        self.finish()
        self.assertEqual(self.row(second)['state'], 'persona_sent', self.row(second).get('error'))
        self.assertEqual(len(self.downloads), 1)
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 2)

    def test_restart_during_preparation_and_a_changed_shared_head_do_not_change_the_task_base(self):
        identity = self.launch()
        self.admission.tick()
        self.store.close()
        (self.repo / 'notes.txt').write_text('a later shared commit')
        shared_head = self.commit()
        self.create_store()
        self.assertEqual(self.row(identity)['state'], 'waiting_environment')
        self.service.tick()
        self.admission.tick()
        self.store.wait_idle(timeout=20)
        job = self.row(identity)
        self.assertEqual(job['state'], 'persona_sent', job.get('error'))
        self.assertEqual(self.git('rev-parse', 'HEAD'), shared_head)
        self.assertEqual(job['start_sha'], self.baseline)
        self.assertEqual(subprocess.check_output(['git', '-C', job['worktree_path'], 'rev-parse', 'HEAD'], text=True).strip(), self.baseline)

    def test_release_cancels_only_the_waiter_and_never_starts_a_late_agent(self):
        identity = self.launch()
        self.admission.tick()
        self.store.action('release', dict(request_id='release-waiter', organization_id=self.org, job_id=identity))
        self.service.tick()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'released')
        self.assertEqual(self.service.store.waiter(identity)['state'], 'cancelled')
        self.assertFalse(any(call[:2] == ['agent', 'start'] for call in self.calls()))

    def test_permission_revocation_is_not_reinterpreted_as_permission_to_launch_unprepared(self):
        identity = self.launch()
        self.admission.tick()
        self.approval.update(auto_prepare=False, auto_prepare_revision='revoked')
        self.service.tick()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertEqual(self.calls(), [])

    def test_failed_preparation_does_not_fall_back_to_an_unprepared_agent(self):
        identity = self.launch()
        self.admission.tick()
        self.service.acquire = lambda *args, **kwargs: (_ for _ in ()).throw(ValueError('fixture download failed'))
        self.service.tick()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertIn('failed', self.row(identity)['error'])
        self.assertEqual(self.calls(), [])

    def test_native_checks_require_their_separate_permission(self):
        self.approval['auto_prepare_checks'] = False
        identity = self.launch()
        self.finish()
        job = self.row(identity)
        self.assertEqual(job['state'], 'persona_sent', job.get('error'))
        plan = self.service.store.get(job['environment_admission']['plan_digest'])
        self.assertEqual(plan['selected_checks'], [])

    def test_expired_planning_and_ready_claims_fence_old_owners(self):
        identity = self.launch()
        old = self.service.store.claim_waiter('old', planning=True, lease_seconds=-1)
        new = self.service.store.claim_waiter(self.admission.owner, planning=True)
        self.assertEqual(old['id'], new['id'])
        self.assertFalse(self.service.store.settle_waiter(old['id'], 'old', 'failed'))
        self.admission.plan(new)
        self.service.tick()
        old = self.service.store.claim_waiter('old', lease_seconds=-1)
        new = self.service.store.claim_waiter(self.admission.owner)
        self.assertEqual(old['id'], new['id'])
        self.assertFalse(self.service.store.settle_waiter(old['id'], 'old', 'resumed'))
        self.admission.resume(new)
        self.store.wait_idle(timeout=20)
        self.assertEqual(self.row(identity)['state'], 'persona_sent', self.row(identity).get('error'))

    def test_restart_after_authorization_before_submission_recovers_one_launch(self):
        identity = self.launch()
        self.admission.tick()
        self.service.tick()
        with patch.object(self.admission, 'schedule'):
            self.admission.tick()
        self.assertEqual(self.row(identity)['launch_stage'], 'environment_ready')
        self.store.close()
        self.create_store()
        self.admission.tick()
        self.store.wait_idle(timeout=20)
        self.assertEqual(self.row(identity)['state'], 'persona_sent', self.row(identity).get('error'))
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)

    def test_an_accepted_launch_with_a_lost_response_is_never_replayed(self):
        identity = self.launch()
        (self.root / 'drop-start-response').touch()
        self.finish()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)
        self.assertFalse(any(call[:2] == ['agent', 'prompt'] for call in self.calls()))
        self.store.close()
        self.create_store()
        self.admission.tick()
        self.store.wait_idle(timeout=20)
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)

    def test_one_cancelled_waiter_does_not_cancel_another_tasks_shared_sdk(self):
        first, second = self.launch(), self.launch('Second')
        self.admission.tick()
        self.admission.tick()
        self.store.action('release', dict(request_id='release-first-only', organization_id=self.org, job_id=first))
        self.service.tick()
        self.admission.tick()
        self.admission.tick()
        self.store.wait_idle(timeout=20)
        self.assertEqual(self.row(first)['state'], 'released')
        self.assertEqual(self.row(second)['state'], 'persona_sent', self.row(second).get('error'))
        self.assertEqual(len(self.downloads), 1)

    def test_graceful_stop_requeues_acquisition_without_failing_the_launch(self):
        identity = self.launch()
        self.admission.tick()
        original = self.service.acquire
        def interrupted(*args, **kwargs):
            self.service.stop.set()
            raise ValueError('fixture interrupted by shutdown')
        self.service.acquire = interrupted
        self.service.tick()
        waiter = self.service.store.waiter(identity)
        self.assertEqual(self.service.store.job(waiter['preparation_id'])['state'], 'queued')
        self.assertEqual(self.row(identity)['state'], 'waiting_environment')
        self.service.stop.clear()
        self.service.acquire = original
        self.service.tick()
        self.admission.tick()
        self.store.wait_idle(timeout=20)
        self.assertEqual(self.row(identity)['state'], 'persona_sent', self.row(identity).get('error'))

    def node_project(self):
        for relative in ('global.json', 'Api/App.csproj', 'Api/Class.cs'):
            (self.repo / relative).unlink()
        (self.repo / 'package.json').write_text(json.dumps(dict(engines=dict(node='>=20 <23'), scripts=dict(test='echo passed'))))
        self.baseline = self.commit()

    def submit_node(self, identity, version='20.19.0'):
        waiter = self.service.store.waiter(identity)
        assistance = self.service.store.assistance(waiter['id'])
        self.assertIsNotNone(assistance, self.row(identity).get('error'))
        allocation = self.store.path.parent / 'environment-assistance' / assistance['id']
        plan = self.service.store.get(assistance['plan_digest'])
        tools = []
        for index, item in enumerate(plan['requirements']):
            if item.get('preparation_method') != 'agent':
                continue
            sdk = allocation / f'sdk-{index}' / 'bin'
            sdk.mkdir()
            for name, measured in (('node', 'v' + version), ('npm', '10.8.0')):
                executable = sdk / name
                executable.write_text('#!/bin/sh\necho ' + measured + '\n')
                executable.chmod(0o755)
            tools.append(dict(index=index, provenance=dict(source='https://example.invalid/node', method='fixture')))
        (allocation / 'result.json').write_text(json.dumps(dict(token=assistance['token'], plan_digest=plan['digest'], tools=tools)))
        return assistance

    def test_node_requires_explicit_assistance_permission_and_never_falls_back_to_project_work(self):
        self.node_project()
        identity = self.launch()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertFalse(any(call[:2] == ['agent', 'start'] for call in self.calls()))

    def test_node_preparation_resumes_after_restart_and_binds_adopted_bytes(self):
        self.node_project()
        self.approval.update(auto_prepare_agent=True, max_active_sessions=1)
        identity = self.launch()
        self.admission.tick()
        assistance = self.submit_node(identity)
        self.assertEqual(self.row(identity)['state'], 'waiting_environment')
        self.assertEqual(sum(call[:2] == ['agent', 'prompt'] for call in self.calls()), 1)
        self.store.close()
        self.create_store()
        self.finish()
        job = self.row(identity)
        self.assertEqual(job['state'], 'persona_sent', job.get('error'))
        self.assertEqual(job['environment_binding']['state'], 'inherited')
        self.assertEqual(self.row(assistance['id'])['state'], 'finished')
        entry = job['toolchain_policy']['policy']['toolchains'][0]
        self.assertEqual(entry['required'], '20.19.0')
        self.assertEqual(entry['adoption']['provenance']['verification'], 'agent_claim')
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 2)
        self.assertTrue(all(len(call[2]) <= 32 for call in self.calls() if call[:2] == ['agent', 'start']))
        self.assertEqual(len(job['toolchain_policy']['policy']['recipes']), 1)
        from validation import ValidationRuns
        from contributions import Contributions
        runner = ValidationRuns(self.projects, lambda _: None, root=self.root / 'node-validation')
        frozen = job['toolchain_policy']
        validation = dict(id='c' * 32, event_id='d' * 64, repository='app', path=str(self.repo),
            target=job['start_sha'], actor='test', started_at='test',
            frozen_plan_digest=frozen['plan_digest'], frozen_policy_digest=frozen['digest'])
        output = runner.root / validation['id']
        output.mkdir(parents=True)
        runner._execute(validation, output)
        self.assertEqual(validation['state'], 'complete', validation)
        contribution = Contributions.__new__(Contributions)
        contribution.store = self.store
        contribution.path_for = lambda _: self.repo
        task = dict(run_id=identity, organization_id=self.org)
        self.assertTrue(contribution.policy_matches(task, validation))
        self.assertFalse(contribution.policy_matches(task, dict(validation, plan_digest='wrong')))

    def test_revoking_assistance_permission_stops_the_helper_and_never_launches_project_work(self):
        self.node_project()
        self.approval['auto_prepare_agent'] = True
        identity = self.launch()
        self.admission.tick()
        assistance = self.submit_node(identity)
        self.approval['auto_prepare_agent'] = False
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertEqual(self.row(assistance['id'])['state'], 'needs_attention')
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)
        self.assertIsNone(self.service.store.waiter(identity).get('preparation_id'))

    def test_assisted_start_lost_response_is_not_replayed_after_restart(self):
        self.node_project()
        self.approval['auto_prepare_agent'] = True
        identity = self.launch()
        (self.root / 'drop-start-response').touch()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.store.close()
        self.create_store()
        self.admission.tick()
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)
        self.assertFalse(any(call[:2] == ['agent', 'prompt'] for call in self.calls()))

    def test_assisted_helper_honors_the_shared_daily_session_budget(self):
        self.node_project()
        self.approval.update(auto_prepare_agent=True, daily_session_cap=1)
        identity = self.launch()
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertIn('daily session budget', self.row(identity)['error'])
        self.assertFalse(any(call[:2] == ['agent', 'start'] for call in self.calls()))

    def test_assistance_refuses_a_root_gateway_before_any_runtime_effect(self):
        self.node_project()
        self.approval['auto_prepare_agent'] = True
        identity = self.launch()
        with patch('environment_assistance.os.geteuid', return_value=0):
            self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'needs_attention')
        self.assertIn('unprivileged', self.row(identity)['error'])
        self.assertEqual(self.calls(), [])

    def test_releasing_a_waiting_launch_cancels_its_helper_and_inspected_helper_can_be_released(self):
        self.node_project()
        self.approval['auto_prepare_agent'] = True
        identity = self.launch()
        self.admission.tick()
        assistance = self.submit_node(identity)
        self.store.action('release', dict(request_id='cancel-node-wait', organization_id=self.org, job_id=identity))
        self.admission.tick()
        self.assertEqual(self.row(identity)['state'], 'released')
        self.assertEqual(self.row(assistance['id'])['state'], 'needs_attention')
        self.store.action('release', dict(request_id='release-inspected-helper', organization_id=self.org, job_id=assistance['id']))
        self.assertEqual(self.row(assistance['id'])['state'], 'released')
        self.assertEqual(sum(call[:2] == ['agent', 'start'] for call in self.calls()), 1)
