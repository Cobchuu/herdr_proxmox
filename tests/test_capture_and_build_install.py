"""Independent capture and validation; fixed root-service request boundary."""
from contextlib import closing, contextmanager
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
from build_service_install import BuildServiceInstall, DEADLINE_SECONDS
from validation import ValidationRuns
import server
import test_contributions

spec = importlib.util.spec_from_file_location('build_install_worker', Path(__file__).parents[1] / 'install/build-service-install.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


@contextmanager
def contribution_case():
    case = test_contributions.ContributionTests()
    try:
        case.setUp()
        yield case
    finally:
        case.doCleanups()


class IndependentCaptureTests(unittest.TestCase):
    def test_capture_only_checks_receipt_without_build_service_or_build(self):
        with contribution_case() as case:
            task = case.candidate()
            head = case._receipt(task)
            run = case.store.snapshot.return_value['jobs'][0]
            run.update(profile_id='worker', completion_token='handoff-token')
            task.update(state='implementing')
            task.pop('head_sha')
            case.service.save(task, 'launch', 'admin')
            case.service.validation = Mock()
            case.service.validation.snapshot.return_value = dict(executor='gateway')
            case.service.action('policy', dict(request_id='capture-only', task_id=task['id'],
                auto_capture=True, auto_validate=False, auto_publish=False), 'admin', 'admin')
            with patch('collaboration.current_run'):
                case.service.advance_automatic()
                case.service.advance_automatic()
            captured = case.service.get(task['id'])
            self.assertEqual(captured['state'], 'review_ready')
            self.assertEqual(captured['head_sha'], head)
            self.assertEqual(captured['completion_receipt']['commit'], head)
            self.assertFalse(captured['await_verification'])
            self.assertNotIn('automation_error', captured)
            case.service.validation.submit.assert_not_called()

    def test_validation_only_waits_for_manual_capture_then_builds_once(self):
        with contribution_case() as case:
            task = case.candidate()
            task.update(state='implementing', auto_capture=False, auto_validate=True)
            task.pop('head_sha')
            case.service.save(task, 'launch', 'admin')
            case.service.validation = Mock()
            case.service.validation.snapshot.return_value = dict(executor='service')
            case.service.validation.submit.return_value = dict(id='build', state='queued', checks=[])
            with patch('collaboration.current_run'):
                case.service.advance_automatic()
                case.service.validation.submit.assert_not_called()
                case.service.action('candidate', dict(request_id='capture-after-wait', task_id=task['id']), 'admin', 'admin')
                case.service.advance_automatic()
                case.service.advance_automatic()
            self.assertEqual(case.service.validation.submit.call_count, 1)

    def test_organization_capture_inherits_without_service_and_validation_stays_gated(self):
        with contribution_case() as case:
            case.store.snapshot.return_value['organizations'] = [dict(id='org')]
            policy = case.service.set_automation_policy(dict(organization_id='org', auto_capture=True), 'admin')
            self.assertTrue(policy['policy']['auto_capture'])
            task = case.service.action('create', dict(case.body, request_id='capture-inherited'), 'admin', 'admin')
            self.assertTrue(task['auto_capture'])
            self.assertFalse(task['auto_validate'])
            with self.assertRaisesRegex(ValueError, 'durable build service'):
                case.service.set_automation_policy(dict(organization_id='org', auto_capture=True, auto_validate=True), 'admin')
            self.assertTrue(case.service.policy('org')['auto_capture'])
            self.assertFalse(case.service.policy('org')['auto_validate'])

    def test_legacy_policy_still_enables_both_and_explicit_capture_false_is_respected(self):
        with contribution_case() as case:
            case.inherited_task()
            with closing(case.service.connect()) as db, db:
                db.execute('UPDATE policies SET data=? WHERE id=?', (json.dumps(dict(auto_validate=True)), 'org'))
            self.assertTrue(case.service.policy('org')['auto_capture'])
            self.assertTrue(case.service.snapshot()['automation']['org']['auto_capture'])
            self.assertTrue(case.task['auto_capture'])
            case.service.set_automation_policy(dict(organization_id='org', auto_capture=False), 'admin')
            task = case.service.action('create', dict(case.body, request_id='manual-capture'), 'admin', 'admin')
            self.assertFalse(task['auto_capture'])
            self.assertTrue(task['auto_validate'])


class BuildServiceInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.queue = self.root / 'requests'
        self.queue.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir()
        self.api = BuildServiceInstall(self.queue, self.state / 'status.json')
        self.validation = Mock()
        self.validation.snapshot.return_value = dict(executor='gateway', runs=[])

    def test_request_is_fixed_atomic_and_blocks_duplicate_install_and_build_submission(self):
        self.assertEqual(self.api.install({}, self.validation), dict(state='queued'))
        self.assertEqual(json.loads((self.queue / 'request.json').read_text()), dict(action='install'))
        self.assertFalse((self.queue / 'request.tmp').exists())
        with self.assertRaisesRegex(ValueError, 'already queued'):
            self.api.install({}, self.validation)
        runs = ValidationRuns(self.root / 'projects', Mock())
        runs.install_lock, runs.install_guard = self.api.lock, self.api.require_idle
        with patch.object(runs, '_submit') as submit:
            with self.assertRaisesRegex(ValueError, 'installation to finish'):
                runs.submit(dict(id='anything'))
            submit.assert_not_called()

    def test_options_active_builds_and_existing_service_are_rejected(self):
        for options in ({'command': 'anything'}, {'action': 'install'}, []):
            with self.assertRaisesRegex(ValueError, 'does not accept options'):
                self.api.install(options, self.validation)
        for snapshot in (dict(executor='service'), dict(executor='gateway', runs=[dict(state='running')])):
            self.validation.snapshot.return_value = snapshot
            with self.assertRaises(ValueError):
                self.api.install({}, self.validation)
        self.assertFalse((self.queue / 'request.json').exists())

    def test_expired_queued_request_allows_an_explicit_retry(self):
        self.api.install({}, self.validation)
        request = self.queue / 'request.json'
        expired = datetime.now(timezone.utc).timestamp() - DEADLINE_SECONDS - 1
        os.utime(request, (expired, expired))
        info = self.api.snapshot()
        self.assertEqual(info['state'], 'failed')
        self.assertIn('did not start', info['error'])
        self.api.require_idle()  # The root worker must reject this expired request too.
        self.assertEqual(self.api.install({}, self.validation), dict(state='queued'))
        self.assertGreater(request.stat().st_mtime, expired)
        self.assertEqual(self.api.snapshot()['state'], 'queued')

    def test_expired_request_cannot_install_late_or_delete_a_newer_retry(self):
        request = self.queue / 'request.json'
        request.write_text('{"action":"install"}', encoding='utf-8')
        expired = datetime.now(timezone.utc).timestamp() - DEADLINE_SECONDS - 1
        os.utime(request, (expired, expired))
        self.assertEqual(worker.DEADLINE_SECONDS, DEADLINE_SECONDS)
        self.assertEqual(self.api.snapshot()['state'], 'failed')
        self.api.require_idle()
        def release_is_trusted():
            # A retry already in flight can land after the worker claims the
            # expired request. Its cleanup must not delete the replacement.
            self.assertFalse(request.exists())
            request.write_text('{"action":"install"}', encoding='utf-8')
            return True
        with patch.multiple(worker, REQUEST=request, STATE=self.state):
            with patch.object(worker.os, 'geteuid', return_value=0, create=True):
                with patch.object(worker, 'release_script_is_trusted', side_effect=release_is_trusted):
                    with patch.object(worker.subprocess, 'run') as run:
                        with self.assertRaisesRegex(ValueError, 'request expired'):
                            worker.main()
                        run.assert_not_called()
        self.assertTrue(request.is_file())
        self.assertFalse((self.state / 'request.json').exists())
        self.assertEqual(self.api.snapshot()['state'], 'queued')

    def test_worker_keeps_queued_or_running_status_through_claiming(self):
        self.api.install({}, self.validation)
        request = self.queue / 'request.json'
        original_status = worker.status
        def status(value, **fields):
            if value == 'running':
                self.assertTrue(request.exists())
                self.assertEqual(self.api.snapshot()['state'], 'queued')
            original_status(value, **fields)
        def install(*args, **kwargs):
            self.assertFalse(request.exists())
            self.assertEqual(self.api.snapshot()['state'], 'running')
            return Mock(returncode=0, stdout='Installed', stderr='')
        with patch.multiple(worker, REQUEST=request, STATE=self.state):
            with patch.object(worker.os, 'geteuid', return_value=0, create=True):
                with patch.object(worker, 'release_script_is_trusted', return_value=True):
                    with patch.object(worker, 'status', side_effect=status), patch.object(worker.subprocess, 'run', side_effect=install):
                        worker.main()
        self.assertEqual(self.api.snapshot()['state'], 'complete')
        self.assertFalse((self.state / 'request.json').exists())

    def test_running_status_and_deadline_allow_explicit_retry(self):
        status = dict(state='running', started_at=datetime.now(timezone.utc).isoformat())
        self.api.state.write_text(json.dumps(status), encoding='utf-8')
        self.assertEqual(self.api.snapshot()['state'], 'running')
        status['started_at'] = (datetime.now(timezone.utc) - timedelta(minutes=12)).isoformat()
        self.api.state.write_text(json.dumps(status), encoding='utf-8')
        self.assertEqual(self.api.snapshot()['state'], 'failed')
        self.assertEqual(self.api.install({}, self.validation)['state'], 'queued')

    def test_http_install_is_admin_only_and_status_requires_authentication(self):
        gateway = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        gateway.token, gateway.build_service_install, gateway.validation = 'a' * 48, self.api, self.validation
        gateway.operators = Mock()
        gateway.operators.identify.side_effect = lambda token: dict(name='operator', role='operator') if token == 'operator' else None
        thread = threading.Thread(target=gateway.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{gateway.server_port}/api/build-service'
        try:
            with self.assertRaises(HTTPError) as refused:
                urlopen(base)
            self.assertEqual(refused.exception.code, 401)
            refused.exception.close()
            with self.assertRaises(HTTPError) as refused:
                urlopen(Request(base + '/install', data=b'{}', headers={'Authorization': 'Bearer operator'}))
            refused.exception.close()
            self.assertFalse((self.queue / 'request.json').exists())
            with urlopen(Request(base + '/install', data=b'{}', headers={'Authorization': 'Bearer ' + gateway.token})) as response:
                result = json.load(response)
            self.assertEqual(result['state'], 'queued')
            with urlopen(Request(base, headers={'Authorization': 'Bearer ' + gateway.token})) as response:
                result = json.load(response)
            self.assertEqual(result['state'], 'queued')
        finally:
            gateway.shutdown()
            gateway.server_close()
            thread.join()

    def test_root_worker_refuses_request_options_and_records_success_or_failure(self):
        script = self.root / 'build-install.sh'
        script.write_text('# fixed release installer', encoding='utf-8')
        request = self.queue / 'request.json'
        for payload, exit_code in ((dict(action='install', command='ignored'), 0), (dict(action='install'), 0), (dict(action='install'), 1)):
            request.write_text(json.dumps(payload), encoding='utf-8')
            with patch.multiple(worker, REQUEST=request, STATE=self.state, SCRIPT=script, RELEASE=self.root):
                with patch.object(worker.os, 'geteuid', return_value=0, create=True), patch.object(worker, 'release_script_is_trusted', return_value=True):
                    with patch.object(worker.subprocess, 'run', return_value=Mock(returncode=exit_code, stdout='output', stderr='details')) as run:
                        if payload != dict(action='install') or exit_code:
                            with self.assertRaises(ValueError):
                                worker.main()
                            self.assertEqual(self.api.snapshot()['state'], 'failed')
                        else:
                            worker.main()
                            self.assertEqual(self.api.snapshot()['state'], 'complete')
                        if payload != dict(action='install'):
                            run.assert_not_called()
                        else:
                            self.assertEqual(run.call_args.args[0], ['/bin/bash', str(script)])
                            self.assertEqual(run.call_args.kwargs['timeout'], 600)
            self.assertFalse(request.exists())

    def test_root_worker_refuses_an_untrusted_release_script(self):
        script = self.root / 'build-install.sh'
        script.write_text('# fixed release installer', encoding='utf-8')
        outsider = self.root.parent / 'outside-release.sh'
        outsider.write_text('# not release content', encoding='utf-8')
        alternate_release = self.root / 'another-release'
        alternate_release.mkdir()
        # Release content this worker may run as root: a regular file inside the
        # release it resolves through. Everything else is refused before bash.
        with patch.multiple(worker, SCRIPT=script, RELEASE=self.root):
            # Model installed release metadata independently of the CI user's
            # ownership and umask. Permission rejection is exercised below.
            with patch.object(type(script), 'stat', return_value=Mock(st_mode=stat.S_IFREG | 0o755, st_uid=0)):
                self.assertTrue(worker.release_script_is_trusted())
        for candidate, release in ((outsider, self.root),          # escapes the release
                                   (script, alternate_release),    # release resolves elsewhere
                                   (self.root, self.root)):        # a directory, not a script
            with self.subTest(script=candidate.name):
                with patch.multiple(worker, SCRIPT=candidate, RELEASE=release):
                    self.assertFalse(worker.release_script_is_trusted())
        outsider.unlink(missing_ok=True)

    def test_release_script_requires_root_ownership_and_safe_posix_permissions(self):
        script = Mock()
        script.resolve.return_value = script
        # Replace only the worker's os binding, not the shared os module: this
        # exercises POSIX policy on Windows without changing pathlib's platform.
        with patch.multiple(worker, SCRIPT=script, RELEASE=self.root, os=SimpleNamespace(name='posix')):
            for uid, mode, trusted in ((0, stat.S_IFREG | 0o755, True),
                                       (1001, stat.S_IFREG | 0o755, False),
                                       (0, stat.S_IFREG | 0o775, False),
                                       (0, stat.S_IFREG | 0o757, False),
                                       (0, stat.S_IFDIR | 0o755, False)):
                with self.subTest(uid=uid, mode=oct(mode)):
                    script.stat.return_value = Mock(st_uid=uid, st_mode=mode)
                    self.assertEqual(worker.release_script_is_trusted(), trusted)
