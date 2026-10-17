#!/usr/bin/env python3
"""Real pinned uv/PBS -> locked restore -> independent validation -> evidence gate.

This must run on the release's unprivileged glibc x64 and arm64 executors. Unit
fixtures cannot qualify vendor extraction/fixups, Python native modules or uv sync.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'web/gateway'))
import environment_artifacts
import environment_launch
from environment_policy import EnvironmentPolicies
from environment_preparation import EnvironmentPreparation
import environment_python
from environment_execution import materialize_execution_policy
from project_analysis import ProjectAnalysis
import toolchain_policy
from validation import ValidationRuns


def command(arguments, cwd, env=None):
    subprocess.run(arguments, cwd=cwd, env=env, check=True, timeout=600)


def main():
    target = environment_artifacts.host_target()
    with tempfile.TemporaryDirectory(prefix='herdr-real-python-') as temporary:
        root = Path(temporary)
        projects = root / 'projects'
        checkout = projects / 'python'
        checkout.mkdir(parents=True)
        specification = environment_python.select([('==3.12.9', 'pep440')], target)
        sdk = environment_artifacts.acquire(specification, root / 'sdks')
        (checkout / 'pyproject.toml').write_text(
            '[project]\nname="herdr-python-smoke"\nversion="0.1.0"\n'
            'requires-python="==3.12.9"\ndependencies=["pytest==8.4.2"]\n', encoding='utf-8')
        (checkout / 'test_smoke.py').write_text(
            'import ssl, sqlite3, sys\ndef test_runtime():\n'
            '    assert sys.version_info[:3] == (3, 12, 9)\n'
            '    assert sys.prefix != sys.base_prefix\n'
            '    assert ssl.OPENSSL_VERSION and sqlite3.sqlite_version\n', encoding='utf-8')
        env = environment_python.clean_environment(root)
        env.update(UV_PYTHON_DOWNLOADS='never')
        command([sdk['uv_executable'], '--no-config', 'lock', '--python', sdk['probe']['executable']], checkout, env)
        environment_python.verify(specification, sdk)
        command(['git', 'init', '-q'], checkout)
        command(['git', 'add', '.'], checkout)
        command(['git', '-c', 'user.name=Herdr smoke', '-c', 'user.email=smoke@example.invalid',
                 'commit', '-qm', 'Frozen Python fixture'], checkout)
        service = EnvironmentPreparation(ProjectAnalysis(projects), root / 'plans.sqlite3', root / 'sdks')
        plan = service.plan('python')
        checks = [item['id'] for item in plan['check_candidates'] if item['arguments'] == ['python', '-m', 'pytest']]
        if not checks or any(item.get('activation') != 'available' for item in plan['requirements']):
            raise RuntimeError(json.dumps(plan))
        plan = service.authorize_restore(plan['digest'], True, 'release_qualification')
        plan = service.select(plan['digest'], checks, 'release_qualification')
        job = service.prepare(plan['digest'])
        service.tick()
        if service.store.job(job['id'])['state'] != 'ready':
            raise RuntimeError(json.dumps(service.store.job(job['id'])))
        policies = EnvironmentPolicies(projects, service.store)
        toolchain_policy.PROJECT_RESOLVER = policies.resolve
        policy = policies.resolve(checkout)
        frozen = dict(policy=policy, digest=toolchain_policy.digest(policy))
        runtime, launch_receipts = materialize_execution_policy(
            policy, checkout, root / 'launch', authorized=True)
        environment_python.verify(specification, sdk)
        binding = environment_launch.binding(dict(frozen, policy=runtime), root / 'launch')
        command(['python', '-I', '-B', '-c', 'import pytest,ssl,sqlite3; assert pytest.__version__ == "8.4.2"'],
                checkout, dict(os.environ, **binding['environment']))
        environment_python.verify(specification, sdk)
        runner = ValidationRuns(projects, lambda _: None, root=root / 'validation')
        run = dict(id='a' * 32, event_id='b' * 64, repository='python', path=str(checkout),
                   target=plan['revision'], actor='release_qualification', started_at='qualification',
                   frozen_plan_digest=policy['plan_digest'], frozen_policy_digest=frozen['digest'])
        output = runner.root / run['id']
        output.mkdir(parents=True)
        runner._execute(run, output)
        environment_python.verify(specification, sdk)
        if run['state'] != 'complete' or not toolchain_policy.evidence_matches(policy, run):
            raise RuntimeError(json.dumps(run))
        if launch_receipts[0]['executable'] == run['environment_restores'][0]['executable']:
            raise RuntimeError('Launch and validation reused one virtual environment.')
        if frozen['digest'] != toolchain_policy.digest(policy):
            raise RuntimeError('Execution materialization changed the approved policy identity.')
        print('Python: pinned archives, real restore, separate launch/validation environments and publication gate passed', flush=True)


if __name__ == '__main__':
    main()
