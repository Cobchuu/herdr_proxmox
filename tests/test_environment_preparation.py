"""Preparation boundaries: identities, publisher artifacts, leases and receipts."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'web/gateway'))
import environment_artifacts as artifacts
import environment_plan
from environment_store import EnvironmentPlanStore
from environment_preparation import EnvironmentPreparation

TARGET = dict(os='linux', architecture='x64', libc='glibc')


def plan(project='app', **changes):
    value = dict(project=project, revision='a' * 40, preview=False, at='2026-10-16',
                 requirements=[dict(capability='dotnet-sdk', state='acquire', version='8.0.100')])
    value.update(changes)
    if value.get('preparation_version'):
        for item in value['requirements']:
            item.setdefault('activation', 'available')
    value['digest'] = environment_plan.digest(value)
    return value


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = EnvironmentPlanStore(Path(self.temp.name) / 'plans.sqlite3')
        self.plan = plan()
        self.store.save(self.plan)

    def test_content_digest_is_verified_and_original_timestamp_is_preserved(self):
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.store.save(dict(self.plan, revision='b' * 40))
        self.store.save(dict(self.plan, at='later'))
        self.assertEqual(self.store.get(self.plan['digest'])['at'], '2026-10-16')

    def test_valid_project_names_allow_dots_and_nested_projects_but_not_traversal(self):
        self.store.save(plan('team/App.NET'))
        for name in ('../app', '/app', 'a/../b', 'a//b'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.store.save(plan(name))

    def test_enqueue_deduplicates_and_preview_or_blockers_are_refused(self):
        first = self.store.enqueue(self.plan['digest'])
        self.assertEqual(first['id'], self.store.enqueue(self.plan['digest'])['id'])
        for value in (plan(preview=True), plan(requirements=[]),
                      plan(requirements=[dict(state='unsupported')])):
            self.store.save(value)
            with self.assertRaises(ValueError):
                self.store.enqueue(value['digest'])

    def test_lease_recovery_fences_the_old_owner(self):
        job = self.store.enqueue(self.plan['digest'])
        self.store.claim('old', lease_seconds=-1)
        claimed = self.store.claim('new')
        self.assertEqual(claimed['id'], job['id'])
        self.assertFalse(self.store.heartbeat(job['id'], 'old'))
        self.assertFalse(self.store.owns(job['id'], 'old'))
        self.assertTrue(self.store.owns(job['id'], 'new'))
        self.assertFalse(self.store.finish(job['id'], 'old', 'ready'))
        self.assertTrue(self.store.finish(job['id'], 'new', 'ready'))

    def test_cancelled_job_cannot_be_completed_and_retry_is_a_new_generation(self):
        job = self.store.enqueue(self.plan['digest'])
        self.store.claim('worker')
        self.store.cancel(job['id'])
        self.assertFalse(self.store.finish(job['id'], 'worker', 'ready'))
        retried = self.store.enqueue(self.plan['digest'], retry=True)
        self.assertEqual(retried['generation'], 2)
        self.assertNotEqual(retried['id'], job['id'])

    def test_a_live_claim_blocks_another_writer_but_not_readers(self):
        job = self.store.enqueue(self.plan['digest'])
        self.assertEqual(self.store.claim('one')['id'], job['id'])
        self.assertIsNone(self.store.claim('two'))
        self.assertEqual(self.store.job(job['id'])['state'], 'running')

    def test_explicit_recheck_reprobes_a_previously_ready_environment(self):
        first = self.store.enqueue(self.plan['digest'])
        self.store.claim('worker')
        self.store.finish(first['id'], 'worker', 'ready')
        self.assertEqual(self.store.enqueue(self.plan['digest'])['id'], first['id'])
        recheck = self.store.enqueue(self.plan['digest'], retry=True)
        self.assertNotEqual(recheck['id'], first['id'])
        self.assertEqual(recheck['state'], 'queued')


class ArtifactTests(unittest.TestCase):
    def test_rust_requires_a_working_cargo_as_well_as_a_compiler(self):
        run = Mock(side_effect=[Mock(returncode=0, stdout='release: 1.85.1\n'),
                                Mock(returncode=0, stdout='cargo 1.85.0 (example)\n')])
        measured = artifacts.probe('rust-toolchain', Path('/sdk'), run=run)
        self.assertEqual(measured['versions'], ['1.85.1'])
        self.assertEqual(measured['cargo_version'], '1.85.0')
        run.side_effect = [Mock(returncode=0, stdout='release: 1.85.1\n'),
                           Mock(returncode=1, stdout='')]
        with self.assertRaisesRegex(ValueError, 'Cargo'):
            artifacts.probe('rust-toolchain', Path('/sdk'), run=run)

    def test_dotnet_resolution_uses_exact_sdk_and_publisher_sha512(self):
        entry = dict(version='8.0.100', files=[dict(rid='linux-x64',
            url='https://builds.dotnet.microsoft.com/dotnet/sdk.tar.gz', hash='a' * 128)])
        read = Mock(return_value=json.dumps({'releases': [{'sdk': entry}]}).encode())
        resolved = artifacts.resolve('dotnet-sdk', '8.0.100', TARGET, read)
        self.assertEqual(resolved['archives'][0]['algorithm'], 'sha512')
        self.assertIn('/8.0/releases.json', read.call_args.args[0])
        with self.assertRaisesRegex(ValueError, 'no .NET SDK'):
            artifacts.resolve('dotnet-sdk', '8.0.200', TARGET, read)

    def test_rust_resolves_compiler_cargo_and_std_separately(self):
        document = '\n'.join(f'[pkg.{name}.target.x86_64-unknown-linux-gnu]\n'
            'available = true\n'
            f'xz_url = "https://static.rust-lang.org/dist/{name}.tar.xz"\n'
            'xz_hash = "' + 'a' * 64 + '"\n' for name in ('rustc', 'cargo', 'rust-std'))
        resolved = artifacts.resolve('rust-toolchain', '1.85.1', TARGET, lambda url: document.encode())
        self.assertEqual([item['component'] for item in resolved['archives']], ['rustc', 'cargo', 'rust-std'])

    def test_untrusted_hosts_credentials_and_weak_metadata_are_rejected(self):
        for url in ('http://static.rust-lang.org/x', 'https://evil.test/x',
                    'https://u:p@static.rust-lang.org/x', 'https://static.rust-lang.org:444/x'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                artifacts.trusted_url(url)
        with self.assertRaisesRegex(ValueError, 'digest'):
            artifacts.artifact('https://static.rust-lang.org/x', '', 'sha256')

    def test_unsafe_archive_entries_never_write_outside_the_stage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, kind in (('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                               ('link', tarfile.SYMTYPE), ('device', tarfile.CHRTYPE)):
                with self.subTest(name=name):
                    archive = root / 'sdk.tar'
                    with tarfile.open(archive, 'w') as stream:
                        entry = tarfile.TarInfo(name)
                        entry.type = kind
                        entry.linkname = '../escape'
                        stream.addfile(entry)
                    destination = root / 'stage'
                    destination.mkdir(exist_ok=True)
                    with self.assertRaises(ValueError):
                        artifacts.unpack(archive, destination)
            self.assertFalse((root / 'escape').exists())

    def test_hash_mismatch_does_not_publish_an_installation(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(artifacts.os, 'geteuid', return_value=1000, create=True):
            spec = dict(capability='dotnet-sdk', version='8.0.100', archives=[dict(
                url='https://builds.dotnet.microsoft.com/sdk.tar.gz', algorithm='sha512', hash='a' * 128)])
            fetch = lambda url, destination, **kwargs: destination.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'digest'):
                artifacts.acquire(spec, Path(folder), fetch=fetch)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_successful_acquisition_publishes_once_and_reprobes_reuse(self):
        content = io.BytesIO()
        with tarfile.open(fileobj=content, mode='w') as stream:
            entry = tarfile.TarInfo('dotnet')
            entry.size = 3
            entry.mode = 0o755
            stream.addfile(entry, io.BytesIO(b'sdk'))
        blob = content.getvalue()
        spec = dict(capability='dotnet-sdk', version='8.0.100', archives=[dict(
            url='https://builds.dotnet.microsoft.com/sdk.tar.gz', algorithm='sha512', hash=hashlib.sha512(blob).hexdigest())])
        fetch = Mock(side_effect=lambda url, destination, **kwargs: destination.write_bytes(blob))
        verify = lambda capability, root: dict(executable=str(root / 'dotnet'), versions=['8.0.100'])
        with tempfile.TemporaryDirectory() as folder, patch.object(artifacts.os, 'geteuid', return_value=1000, create=True):
            first = artifacts.acquire(spec, folder, fetch=fetch, verify=verify)
            second = artifacts.acquire(spec, folder, fetch=fetch, verify=verify)
            self.assertEqual(fetch.call_count, 1)
            self.assertEqual(first, second)
            self.assertTrue(Path(first['probe']['executable']).is_file())
            Path(first['probe']['executable']).with_name('herdr-receipt.json').unlink()
            repaired = artifacts.acquire(spec, folder, fetch=fetch, verify=verify)
            self.assertEqual(fetch.call_count, 2)
            self.assertTrue(Path(repaired['probe']['executable']).is_file())
            quarantines = list(Path(folder).glob('.unverified-*'))
            self.assertEqual(len(quarantines), 1)
            self.assertEqual((quarantines[0] / 'dotnet').read_bytes(), b'sdk')


class ServiceTests(unittest.TestCase):
    def test_installed_host_tools_remain_ready_while_activation_blocks_preparation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            analysis = Mock()
            analysis.project.return_value = root
            requirements = [dict(tool=tool, label=tool, notation='semver', components=['.'],
                discovered=[dict(constraint=constraint, selected=selected, notation='semver')],
                assessment=dict(measured=measured))
                for tool, constraint, selected, measured in (
                    ('node', '>=20 <23', '', '22.1.0'),
                    ('dotnet', '', '8.0.100', '8.0.100'))]
            analysis.effective.return_value = dict(project='app', requirements=requirements,
                source=dict(scope='committed', revision='a' * 40))
            resolve = Mock(return_value=dict(capability='dotnet-sdk', version='8.0.100'))
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks', resolve=resolve)
            with patch('environment_preparation.project_git.git', return_value=''):
                value = service.plan('app', 'a' * 40)
            node, dotnet = value['requirements']
            self.assertEqual(node['installed'], ['22.1.0'])
            self.assertEqual(node['state'], 'ready')
            self.assertEqual(node['activation'], 'unavailable')
            self.assertNotIn('No installed version', node['reason'])
            self.assertEqual(dotnet['activation'], 'available')
            with self.assertRaisesRegex(ValueError, 'activation'):
                service.prepare(value['digest'])
            with self.assertRaisesRegex(ValueError, 'activation'):
                service.store.enqueue(value['digest'])

    def test_untracked_notes_are_allowed_but_selection_files_are_not(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'notes.txt').write_text('unrelated notes', encoding='utf-8')
            analysis = Mock()
            analysis.project.return_value = root
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks',
                acquire=Mock(return_value={'probe': {'executable': str(root / 'sdk/dotnet')}}))
            value = plan(preparation_version=1, requirements=[dict(state='acquire', version='8.0.100',
                artifact={'capability': 'dotnet-sdk'}, capability='dotnet-sdk', components=['.'])])
            service.store.save(value)

            def git(checkout, *arguments):
                if arguments[0] == 'status':
                    self.assertIn('--untracked-files=no', arguments)
                return 'a' * 40 if arguments[0] == 'rev-parse' else ''

            with patch('environment_preparation.project_git.git', side_effect=git), \
                    patch('environment_preparation.subprocess.run', return_value=Mock(returncode=0, stdout='8.0.100\n')):
                first = service.prepare(value['digest'])
                service.tick()
                self.assertEqual(service.store.job(first['id'])['state'], 'ready')
                (root / 'global.json').write_text('{"sdk":{"version":"9.0.100"}}', encoding='utf-8')
                second = service.prepare(value['digest'], retry=True)
                service.tick()
            self.assertEqual(service.store.job(second['id'])['state'], 'failed')
            self.assertIn('uncommitted SDK selection', service.store.job(second['id'])['error'])

    def test_contextual_verification_is_required_before_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            analysis = Mock()
            analysis.project.return_value = root
            receipt = dict(artifact_id='receipt', probe=dict(executable=str(root / 'sdk/dotnet')))
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks',
                acquire=Mock(return_value=receipt))
            value = plan(preparation_version=1, requirements=[dict(state='acquire', version='8.0.100',
                artifact={'capability': 'dotnet-sdk'}, capability='dotnet-sdk', components=['.'])])
            service.store.save(value)
            job = service.prepare(value['digest'])
            with patch('environment_preparation.project_git.git', side_effect=lambda root, *args: 'a' * 40 if args[0] == 'rev-parse' else ''), \
                    patch('environment_preparation.subprocess.run', return_value=Mock(returncode=0, stdout='8.0.100\n')):
                service.tick()
            ready = service.store.job(job['id'])
            self.assertEqual(ready['state'], 'ready')
            self.assertEqual(ready['checks'], 'not_run')
            self.assertEqual(ready['receipts'][0]['artifact_id'], 'receipt')

    def test_revision_changes_during_download_cannot_certify_the_old_plan(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            analysis = Mock()
            analysis.project.return_value = root
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks',
                acquire=Mock(return_value={'probe': {'executable': str(root / 'sdk/dotnet')}}))
            value = plan(preparation_version=1, requirements=[dict(state='acquire', version='8.0.100',
                artifact={'capability': 'dotnet-sdk'}, capability='dotnet-sdk', components=['.'])])
            service.store.save(value)
            job = service.prepare(value['digest'])
            with patch('environment_preparation.project_git.git', side_effect=['a' * 40, '', 'b' * 40]), \
                    patch('environment_preparation.subprocess.run') as probe:
                service.tick()
            self.assertEqual(service.store.job(job['id'])['state'], 'failed')
            probe.assert_not_called()

    def test_source_changes_stop_before_sdk_acquisition(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            analysis = Mock()
            analysis.project.return_value = root
            acquire = Mock()
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks', acquire=acquire)
            value = plan(preparation_version=1, requirements=[dict(state='acquire', artifact={})])
            service.store.save(value)
            job = service.store.enqueue(value['digest'])
            with patch('environment_preparation.project_git.git', return_value='b' * 40):
                service.tick()
            self.assertEqual(service.store.job(job['id'])['state'], 'failed')
            acquire.assert_not_called()

    def test_failed_or_cancelled_preparation_never_becomes_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            analysis = Mock()
            analysis.project.return_value = root
            service = EnvironmentPreparation(analysis, root / 'plans.sqlite3', root / 'sdks',
                acquire=Mock(side_effect=ValueError('native dependency missing')))
            value = plan(preparation_version=1, requirements=[dict(state='acquire',
                artifact={'capability': 'dotnet-sdk'}, capability='dotnet-sdk', components=['.'])])
            service.store.save(value)
            job = service.prepare(value['digest'])
            with patch('environment_preparation.project_git.git', side_effect=['a' * 40, '']):
                self.assertTrue(service.tick())
            self.assertEqual(service.store.job(job['id'])['state'], 'failed')
            self.assertIn('native dependency', service.store.job(job['id'])['error'])


class HttpTests(unittest.TestCase):
    def test_preparation_requires_admin_and_gets_never_queue_work(self):
        import threading
        from urllib.request import Request, urlopen
        from urllib.error import HTTPError
        import server
        gateway = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        gateway.token = 'a' * 48
        gateway.environments = Mock()
        gateway.environments.plan.return_value = {'digest': 'b' * 64}
        gateway.environments.store.job.return_value = {'state': 'queued'}
        gateway.operators = Mock()
        gateway.operators.identify.side_effect = lambda token: {'name': 'operator', 'role': 'operator'} if token == 'operator' else None
        thread = threading.Thread(target=gateway.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{gateway.server_port}/api/projects/environment'
        try:
            for token in ('', 'operator'):
                with self.subTest(token=token), self.assertRaises(HTTPError) as refused:
                    urlopen(Request(base + '/plan', data=b'{"path":"app"}', headers={'Authorization': 'Bearer ' + token}))
                refused.exception.close()
            gateway.environments.plan.assert_not_called()
            with urlopen(Request(base + '/plan', data=b'{"path":"app"}', headers={'Authorization': 'Bearer ' + gateway.token})) as response:
                self.assertEqual(json.load(response)['digest'], 'b' * 64)
            gateway.environments.plan.assert_called_once_with('app', None)
            with urlopen(Request(base + '?job=id', headers={'Authorization': 'Bearer ' + gateway.token})) as response:
                self.assertEqual(json.load(response)['state'], 'queued')
            gateway.environments.prepare.assert_not_called()
        finally:
            gateway.shutdown()
            gateway.server_close()
            thread.join()


if __name__ == '__main__':
    unittest.main()
