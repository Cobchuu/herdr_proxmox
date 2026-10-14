"""The SDK install client and its root worker; no service or installer runs."""
import importlib.util
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'web/gateway'))
from sdk_install import SdkInstall

worker_spec = importlib.util.spec_from_file_location('sdk_install_worker', Path(__file__).parents[1] / 'install/sdk-install.py')
worker = importlib.util.module_from_spec(worker_spec)
worker_spec.loader.exec_module(worker)


def release_tree(root, entries, installed=()):
    """A release whose catalog points at declarations and installs in the tree.

    Laid out like a deployed release: the catalog lives under `install/`, so the
    release root is its parent, exactly as the client derives it in production.
    The version lives in the repository's own declaration, so each toolchain gets
    a file to read rather than a version copied into the catalog.
    """
    (root / 'install').mkdir(exist_ok=True)
    for name, version in entries.items():
        (root / f'{name}.json').write_text(json.dumps({'version': version}))
    catalog = root / 'install/toolchains.json'
    catalog.write_text(json.dumps({
        name: {'label': name.title(),
               'version_source': {'file': f'{name}.json', 'key': 'version'},
               'install_root': str(root / f'{name}-{{version}}'),
               'executable': str(root / f'{name}-{{version}}/bin/{name}'),
               'script': 'install/dev-tools-install.sh'}
        for name, version in entries.items()}))
    for name in installed:
        executable = root / f'{name}-{entries[name]}/bin/{name}'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('SDK fixture')
    return catalog


class SdkClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.queue = self.root / 'queue'
        self.queue.mkdir()
        self.catalog = release_tree(self.root, {'flutter': '1.0.0'})
        self.service = SdkInstall(self.queue, self.root / 'status.json', self.catalog)

    def test_installation_is_queued_once_and_visible(self):
        status = self.service.snapshot()
        self.assertEqual(status['state'], 'idle')
        self.assertTrue(status['supported'])
        self.assertEqual(status['missing'], ['flutter'])
        self.assertEqual(status['toolchains']['flutter'],
                         {'label': 'Flutter', 'required': '1.0.0', 'declared_by': 'flutter.json#version',
                          'executable': str(self.root / 'flutter-1.0.0/bin/flutter'), 'installed': False})
        self.assertEqual(self.service.install({})['state'], 'queued')
        self.assertEqual(self.service.snapshot()['state'], 'queued')
        # The queued toolchain is readable before the root service claims it.
        self.assertEqual(self.service.snapshot()['toolchain'], 'flutter')
        request = json.loads((self.queue / 'request.json').read_text())
        self.assertEqual(request, {'action': 'install', 'toolchain': 'flutter'})
        with self.assertRaisesRegex(ValueError, 'already running'):
            self.service.install({})

    def test_options_are_rejected_and_an_installed_toolchain_is_not_reinstalled(self):
        with self.assertRaises(ValueError):
            self.service.install({'version': 'latest'})
        executable = self.root / 'flutter-1.0.0/bin/flutter'
        executable.parent.mkdir(parents=True)
        executable.write_text('SDK fixture')
        with self.assertRaisesRegex(ValueError, 'already installed'):
            self.service.install({})

    def test_missing_service_and_failed_state_are_explicit(self):
        unsupported = SdkInstall(self.root / 'missing', self.root / 'status.json', self.catalog)
        with self.assertRaisesRegex(ValueError, 'root first'):
            unsupported.install({})
        (self.root / 'status.json').write_text(json.dumps({'state': 'failed', 'error': 'network'}))
        self.assertEqual(self.service.install({})['state'], 'queued')

    def test_installer_progress_is_reported_and_optional(self):
        # The installer writes this file and the gateway only reads it, so a
        # missing or malformed file must mean "no percentage" rather than a
        # broken card, and an implausible one must not be shown as progress.
        progress = self.service.state.parent / 'progress.json'
        started = (datetime.now(timezone.utc) - timedelta(seconds=5)).isoformat()
        self.service.state.write_text(json.dumps({'state': 'running', 'started_at': started}))
        self.assertIsNone(self.service.progress(started))
        for broken in ('{not json', '[]', '{"percent": "half"}',
                       '{"percent": -1}', '{"percent": 101}', 'null'):
            progress.write_text(broken)
            self.assertIsNone(self.service.progress(started), broken)
        at = datetime.now(timezone.utc).isoformat()
        progress.write_text(json.dumps({'percent': 43, 'phase': 'download',
                                        'at': at}))
        self.assertEqual(self.service.progress(started),
                         {'percent': 43, 'phase': 'download',
                          'at': at})
        self.assertEqual(self.service.snapshot()['progress']['percent'], 43)

    def test_progress_must_belong_to_the_current_running_install(self):
        now = datetime.now(timezone.utc)
        started = (now - timedelta(seconds=5)).isoformat()
        self.service.state.write_text(json.dumps({'state': 'running', 'started_at': started}))
        path = self.service.state.parent / 'progress.json'
        for at in ((now - timedelta(days=1)).isoformat(), (now + timedelta(days=1)).isoformat(),
                   'invalid', now.replace(tzinfo=None).isoformat(), None):
            path.write_text(json.dumps({'percent': 100, 'phase': 'done', 'at': at}))
            self.assertIsNone(self.service.snapshot()['progress'], at)
        path.write_text(json.dumps({'percent': 43, 'phase': 'download', 'at': now.isoformat()}))
        for state in ('idle', 'complete', 'failed'):
            self.service.state.write_text(json.dumps({'state': state, 'started_at': started}))
            self.assertIsNone(self.service.snapshot()['progress'], state)
        self.service.state.write_text(json.dumps({'state': 'failed'}))
        self.service.install({})
        self.assertIsNone(self.service.snapshot()['progress'])

    def test_malformed_status_is_reported_without_breaking_polling(self):
        self.service.state.write_text('{broken')
        self.assertEqual(self.service.snapshot()['state'], 'failed')

    def test_a_stale_installation_of_another_version_reads_as_missing(self):
        # The install root is versioned, so an older SDK on disk cannot pass for
        # the declared one.
        (self.root / 'flutter-0.9.0').mkdir()
        self.assertEqual(self.service.snapshot()['missing'], ['flutter'])

    def test_every_declared_toolchain_reports_its_own_state(self):
        catalog = release_tree(self.root, {'flutter': '1.0.0', 'rust': '1.80.0'}, installed=['rust'])
        service = SdkInstall(self.queue, self.root / 'status.json', catalog)
        status = service.snapshot()
        self.assertEqual(status['missing'], ['flutter'])
        self.assertTrue(status['toolchains']['rust']['installed'])
        self.assertEqual(status['toolchains']['rust']['required'], '1.80.0')

    def test_a_named_toolchain_is_installed_while_several_are_missing(self):
        catalog = release_tree(self.root, {'flutter': '1.0.0', 'go': '1.23.0', 'rust': '1.80.0'},
                               installed=['rust'])
        service = SdkInstall(self.queue, self.root / 'status.json', catalog)
        self.assertEqual(service.snapshot()['missing'], ['flutter', 'go'])
        self.assertEqual(service.install({'toolchain': 'go'})['toolchain'], 'go')
        request = json.loads((self.queue / 'request.json').read_text())
        self.assertEqual(request['toolchain'], 'go')

    def test_an_unnamed_request_refuses_to_choose_between_several(self):
        catalog = release_tree(self.root, {'flutter': '1.0.0', 'go': '1.23.0'})
        service = SdkInstall(self.queue, self.root / 'status.json', catalog)
        with self.assertRaisesRegex(ValueError, 'flutter, go'):
            service.install({})

    def test_an_undeclared_toolchain_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'does not provision'):
            self.service.install({'toolchain': 'go'})
        self.assertFalse((self.queue / 'request.json').exists())

    def test_one_missing_toolchain_does_not_make_a_multiple_catalog_unambiguous(self):
        catalog = release_tree(self.root, {'flutter': '1.0.0', 'go': '1.23.0'}, installed=('flutter',))
        service = SdkInstall(self.queue, self.root / 'status.json', catalog)
        self.assertEqual(service.snapshot()['missing'], ['go'])
        with self.assertRaisesRegex(ValueError, 'Several toolchains are declared'):
            service.install({})
        for name in (None, [], '', {}):
            with self.assertRaises(ValueError):
                service.install({'toolchain': name})

    def test_a_new_request_clears_the_previous_installation_error(self):
        (self.root / 'status.json').write_text(json.dumps({'state': 'failed', 'toolchain': 'old', 'error': 'old error'}))
        self.service.install({'toolchain': 'flutter'})
        status = self.service.snapshot()
        self.assertEqual((status['state'], status['toolchain']), ('queued', 'flutter'))
        self.assertNotIn('error', status)

    def test_an_sdk_directory_without_an_executable_is_missing(self):
        (self.root / 'flutter-1.0.0').mkdir()
        self.assertEqual(self.service.snapshot()['missing'], ['flutter'])

    def test_a_toolchain_without_a_declared_version_cannot_be_installed(self):
        # A catalog entry that names no declaration has no version to install,
        # so it must refuse rather than install something arbitrary.
        self.catalog.write_text(json.dumps({'flutter': {'label': 'Flutter',
                                                        'install_root': str(self.root / 'flutter-{version}'),
                                                        'script': 'install/dev-tools-install.sh'}}))
        status = self.service.snapshot()
        self.assertEqual(status['toolchains']['flutter']['required'], '')
        self.assertEqual(status['missing'], [])
        with self.assertRaisesRegex(ValueError, 'declares no version'):
            self.service.install({'toolchain': 'flutter'})

    def test_a_release_without_a_readable_catalog_claims_nothing(self):
        for broken in ('{not json', json.dumps({'flutter': 'not an entry'}), json.dumps([])):
            self.catalog.write_text(broken)
            status = self.service.snapshot()
            self.assertEqual(status['toolchains'], {})
            self.assertEqual(status['missing'], [])
            with self.assertRaisesRegex(ValueError, 'does not provision'):
                self.service.install({})
        self.catalog.unlink()
        self.assertEqual(self.service.snapshot()['toolchains'], {})


class SdkWorkerTests(unittest.TestCase):
    def test_sdk_probe_drops_root_privileges_and_rejects_failed_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'flutter'
            executable.write_text('fixture')
            entry = {'executable': str(executable)}
            for code, expected in ((0, '1.2.3'), (1, None)):
                with patch.object(worker.subprocess, 'run', return_value=Mock(
                        returncode=code, stdout='{"frameworkVersion":"1.2.3"}')) as run:
                    self.assertEqual(worker.probe(entry, '1.2.3'), expected)
                self.assertEqual(run.call_args.args[0][:6], ['runuser', '-u', 'herdr', '--', 'env', '-i'])

    def test_only_an_install_action_naming_a_toolchain_is_accepted(self):
        self.assertEqual(worker.parse_request('{"action": "install"}'), {'action': 'install'})
        self.assertEqual(worker.parse_request('{"action": "install", "toolchain": "go"}'),
                         {'action': 'install', 'toolchain': 'go'})
        for text in ('[]', '{}', '"install"', 'null', '{"action": "other"}',
                     '{"action": "install", "version": "v1"}', '{"action": "install", "script": "/bin/sh"}'):
            with self.assertRaises(ValueError):
                worker.parse_request(text)

    def test_the_catalog_resolves_only_to_installers_inside_the_release(self):
        with tempfile.TemporaryDirectory() as folder:
            release = Path(folder)
            (release / 'install').mkdir()
            (release / 'install/dev-tools-install.sh').write_text('echo hi')
            (release / 'outside.sh').write_text('echo pwned')
            (release / 'install/link.sh').symlink_to(release / 'outside.sh')
            good = {'go': {'script': 'install/dev-tools-install.sh'}}
            self.assertEqual(worker.resolve('go', good, release),
                             (release / 'install/dev-tools-install.sh').resolve())
            for entry in ({'go': {'script': '../outside.sh'}},
                          {'go': {'script': 'install/link.sh'}},
                          {'go': {'script': 'install/missing.sh'}},
                          {'go': {}},
                          {'go': 'not an entry'},
                          {'../outside.sh': {'script': 'install/dev-tools-install.sh'}}):
                with self.assertRaisesRegex(ValueError, 'does not provision'):
                    worker.resolve('go', entry, release)

    def test_the_declared_version_comes_from_the_release_declaration(self):
        with tempfile.TemporaryDirectory() as folder:
            release = Path(folder)
            (release / '.fvmrc').write_text('{"flutter": "1.2.3"}')
            entry = {'version_source': {'file': '.fvmrc', 'key': 'flutter'}}
            self.assertEqual(worker.declared_version(entry, release), '1.2.3')
            # A request cannot supply the version, and an unusable declaration
            # must not be guessed at.
            (release / '.fvmrc').write_text('{"flutter": "latest"}')
            self.assertIsNone(worker.declared_version(entry, release))
            (release / '.fvmrc').write_text('{broken')
            self.assertIsNone(worker.declared_version(entry, release))
            self.assertIsNone(worker.declared_version({'version_source': 'not a mapping'}, release))

    def test_an_unreadable_or_empty_catalog_refuses(self):
        with tempfile.TemporaryDirectory() as folder:
            missing = Path(folder) / 'absent.json'
            for path in (missing, self._write(Path(folder) / 'a.json', '{broken'),
                         self._write(Path(folder) / 'b.json', '[]'),
                         self._write(Path(folder) / 'c.json', '{}')):
                with self.assertRaisesRegex(ValueError, 'readable SDK catalog'):
                    worker.load_catalog(path)

    @staticmethod
    def _write(path, text):
        path.write_text(text)
        return path

    def _release(self, root, entries):
        (root / 'install').mkdir(parents=True, exist_ok=True)
        (root / 'install/dev-tools-install.sh').write_text('echo hi')
        (root / '.fvmrc').write_text(json.dumps({'flutter': '1.0.0'}))
        catalog = root / 'install/toolchains.json'
        catalog.write_text(json.dumps({
            name: {'label': name.title(),
                   'version_source': {'file': '.fvmrc', 'key': 'flutter'},
                   'install_root': str(root / f'{name}-{{version}}'),
                   'executable': str(root / f'{name}-{{version}}/bin/{name}'),
                   'script': 'install/dev-tools-install.sh'} for name in entries}))
        return catalog

    def test_worker_runs_the_named_release_installer_and_records_status(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release, state, request = root / 'release', root / 'state', root / 'request/request.json'
            request.parent.mkdir()
            catalog = self._release(release, {'flutter', 'go'})
            request.write_text('{"action": "install", "toolchain": "go"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', request), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install', return_value='Go ready') as install, \
                    patch.object(worker, 'probe', return_value='1.0.0') as probe:
                worker.main()
            install.assert_called_once_with(release / 'install/dev-tools-install.sh')
            probe.assert_called_once()
            self.assertFalse(request.exists())
            self.assertEqual(json.loads((state / 'status.json').read_text()),
                             {'state': 'complete', 'output': 'Go ready', 'toolchain': 'go',
                              'required': '1.0.0', 'reported': '1.0.0'})

    def test_an_installation_that_reports_another_version_is_a_failure(self):
        # The install can succeed and still produce the wrong SDK. Recording
        # that as complete would be exactly the false claim this guards against.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release, state, request = root / 'release', root / 'state', root / 'request/request.json'
            request.parent.mkdir()
            catalog = self._release(release, {'flutter'})
            request.write_text('{"action": "install"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', request), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install', return_value='ok'), \
                    patch.object(worker, 'probe', return_value='0.9.0'):
                with self.assertRaisesRegex(ValueError, 'reports 0.9.0'):
                    worker.main()
            saved = json.loads((state / 'status.json').read_text())
            self.assertEqual(saved['state'], 'failed')
            self.assertIn('Required flutter 1.0.0', saved['error'])

    def test_a_release_declaring_no_version_installs_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release, state, request = root / 'release', root / 'state', root / 'request/request.json'
            request.parent.mkdir()
            catalog = self._release(release, {'flutter'})
            (release / '.fvmrc').write_text('{}')
            request.write_text('{"action": "install"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', request), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install') as install:
                with self.assertRaisesRegex(ValueError, 'declares no version'):
                    worker.main()
            install.assert_not_called()

    def test_a_bare_action_needs_an_unambiguous_catalog(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release, state = root / 'release', root / 'state'
            single = root / 'request-single'
            catalog = self._release(release, {'flutter'})
            single.parent.mkdir(exist_ok=True)
            single.write_text('{"action": "install"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', single), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install', return_value='ok'), \
                    patch.object(worker, 'probe', return_value='1.0.0'):
                worker.main()
            # Two entries make a nameless request ambiguous, so it is refused
            # rather than silently provisioning whichever sorts first.
            several = root / 'request-several'
            catalog.write_text(json.dumps({
                name: {'label': name.title(), 'version_source': {'file': '.fvmrc', 'key': 'flutter'},
                       'script': 'install/dev-tools-install.sh'} for name in ('flutter', 'go')}))
            several.write_text('{"action": "install"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', several), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install') as install:
                with self.assertRaisesRegex(ValueError, 'Unsupported SDK install request'):
                    worker.main()
            install.assert_not_called()

    def test_worker_reports_failure_without_leaving_the_request(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            release, state, request = root / 'release', root / 'state', root / 'request/request.json'
            request.parent.mkdir()
            catalog = self._release(release, {'flutter'})
            request.write_text('{"action": "install"}')
            with patch.object(worker, 'STATE', state), patch.object(worker, 'REQUEST', request), \
                    patch.object(worker, 'RELEASE', release), patch.object(worker, 'CATALOG', catalog), \
                    patch.object(worker.os, 'geteuid', return_value=0, create=True), \
                    patch.object(worker, 'install', side_effect=ValueError('SDK installation failed.')):
                with self.assertRaises(ValueError):
                    worker.main()
            self.assertFalse(request.exists())
            saved = json.loads((state / 'status.json').read_text())
            self.assertEqual(saved['state'], 'failed')
            self.assertIn('failed', saved['error'])

    def test_installer_failure_keeps_stderr_after_noisy_stdout(self):
        result = Mock(returncode=1, stdout='apt output ' * 1000, stderr='Pinned SDK release is unavailable')
        with patch.object(worker.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(ValueError, 'Pinned SDK release is unavailable'):
                worker.install(Path('/opt/herdr-web/install/dev-tools-install.sh'))


if __name__ == '__main__':
    unittest.main()
