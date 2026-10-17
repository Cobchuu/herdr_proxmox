"""Python recipes are portable identities; environments and restore receipts are not.

Nothing here lists tasks or executes a manager during planning. Restore can load
project/build code and has its own authorization. A crash after 'running' is
inspection-required, never an implicit replay of dependency installation.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tomllib

import environment_plan
import environment_python


def identity(value):
    return hashlib.sha256(environment_plan.canonical(value).encode()).hexdigest()


def recipe(component, paths, read, specification, revision):
    paths = set(paths)
    directory = PurePosixPath(component)
    def path(name):
        return (directory / name).as_posix()
    contents = {}
    def read_input(name):
        if name not in contents:
            data = read(name)
            if data is None:
                raise ValueError('Python environment input is not a readable committed regular file: ' + name)
            contents[name] = data
        return contents[name]
    names = [path(name) for name in ('pyproject.toml', 'uv.lock', 'uv.toml',
                                    'poetry.lock', 'requirements.txt', 'requirements.lock', '.python-version')]
    inputs = {name: hashlib.sha256(read_input(name)).hexdigest() for name in names if name in paths}
    project = tomllib.loads(read_input(path('pyproject.toml')).decode()) if path('pyproject.toml') in paths else {}
    if path('poetry.lock') in paths or 'poetry' in project.get('tool', {}):
        raise ValueError('Poetry restoration needs a pinned manager adapter; it is not silently replaced with pip.')
    # A workspace owner is a different fact from a component. Refuse rather than
    # sync members independently into competing environments.
    for ancestor in (directory, *directory.parents):
        manifest = (ancestor / 'pyproject.toml').as_posix()
        if manifest in paths and tomllib.loads(read_input(manifest).decode()).get('tool', {}).get('uv', {}).get('workspace'):
            raise ValueError('Python workspace environment ownership is not supported yet.')
    if path('uv.lock') in paths:
        manager, dependency = 'uv', 'uv.lock'
    elif path('requirements.lock') in paths:
        manager, dependency = 'pip', 'requirements.lock'
        requirements = read_input(path(dependency)).decode()
        # Keep recursive include/configuration files out of this initial contract.
        # Hash-locked lines may span lines; no resolver options or local paths.
        for line in requirements.replace('\\\n', ' ').splitlines():
            line = line.strip()
            if line and not line.startswith('#'):
                import re
                if not re.fullmatch(r'[A-Za-z0-9_.-]+(?:\[[A-Za-z0-9_,.-]+\])?==[^\s;]+(?:\s+--hash=sha256:[0-9a-f]{64})+', line):
                    raise ValueError('pip restoration requires requirements.lock with exact versions and SHA-256 hashes; includes and options are unsupported.')
    elif any(path(name) in paths for name in ('requirements.txt', 'pyproject.toml')):
        raise ValueError('Python dependency restoration requires uv.lock or a hash-locked requirements.lock.')
    else:
        manager, dependency = 'venv', None
    value = dict(schema=1, component=component, revision=revision, manager=manager,
                 manager_version=(specification['uv_version'] if manager == 'uv' else
                                  'stdlib-venv' if manager == 'venv' else 'ensurepip-from-base-artifact'),
                 base_artifact=identity(specification), inputs=inputs, dependency=dependency,
                 groups=[], extras=[], editable=False, target=specification['target'], requires_restore=manager != 'venv')
    return dict(value, digest=identity(value))


def valid_recipe(value):
    return isinstance(value, dict) and value.get('digest') == identity({key: item for key, item in value.items() if key != 'digest'})


def write(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, sort_keys=True), encoding='utf-8')
    temporary.replace(path)


def verify_probe(observed, entry, env_path, sdk):
    functionality = observed.get('functionality') or {}
    base = sdk.get('probe', {}).get('functionality', {}).get('prefix')
    if (observed.get('versions') != [entry['required']] or not base
            or Path(functionality.get('prefix', '')).resolve() != env_path.resolve()
            or Path(functionality.get('base_prefix', '')).resolve() != Path(base).resolve()
            or functionality.get('prefix') == functionality.get('base_prefix')):
        raise ValueError('The Python environment did not select its frozen interpreter.')


def materialize_entry(entry, checkout, caches, *, authorized=False, run=subprocess.run):
    """Materialize one adapter-owned entry; orchestration copies the policy."""
    checkout, caches = Path(checkout).resolve(), Path(caches).absolute()
    value = entry.get('restore_recipe')
    if not valid_recipe(value):
        raise ValueError('The frozen Python recipe failed its integrity check.')
    if value['manager'] != 'venv' and not authorized:
        raise ValueError('Python dependency restoration requires separate project-code permission.')
    sdk = entry['artifact_receipt']
    environment_python.verify(sdk['specification'], sdk)
    if sdk['artifact_id'] != value['base_artifact']:
        raise ValueError('Python recipe and interpreter identities differ.')
    for name, expected in value['inputs'].items():
        from project_access import open_project
        with open_project(checkout, name) as descriptor, os.fdopen(os.dup(descriptor), 'rb') as stream:
            actual = hashlib.sha256(stream.read(262145)).hexdigest()
        if actual != expected:
            raise ValueError('A Python recipe input changed: ' + name)
    directory = caches / 'python' / value['digest']
    if caches.is_symlink() or directory.is_symlink():
        raise ValueError('Execution environment directories must not be symlinks.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt_file = directory / 'restore.json'
    env_path = directory / 'environment'
    executable = env_path / 'bin/python'
    cwd = checkout / value['component']
    if not cwd.resolve().is_relative_to(checkout):
        raise ValueError('A Python component escaped its execution checkout.')
    if receipt_file.exists():
        receipt = json.loads(receipt_file.read_text(encoding='utf-8'))
        if (receipt.get('state') != 'complete' or receipt.get('recipe_digest') != value['digest']
                or receipt.get('checkout') != str(checkout) or receipt.get('executable') != str(executable)):
            raise ValueError('Python restoration needs inspection; an uncertain operation is not replayed.')
    else:
        receipt = dict(schema=1, state='running', recipe_digest=value['digest'],
            base_artifact=sdk['artifact_id'], checkout=str(checkout), executable=str(executable),
            environment=str(env_path), commands=[], authorized=authorized)
        # Exclusive creation fences two launch/recovery callers. An empty or
        # partial marker after a crash is uncertainty, never permission to retry.
        try:
            with receipt_file.open('x', encoding='utf-8') as stream:
                json.dump(receipt, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
        except FileExistsError as error:
            raise ValueError('Python restoration is already claimed; inspect its receipt.') from error
        env = environment_python.clean_environment(directory)
        import environment_adapters
        env.update(environment_adapters.get(entry['name']).environment(sdk['probe']['executable'], str(env_path)))
        if value['manager'] == 'uv':
            commands = [[sdk['uv_executable'], '--no-config', 'venv', '--python', sdk['probe']['executable'], str(env_path)],
                [sdk['uv_executable'], '--no-config', 'sync', '--frozen', '--no-default-groups', '--no-editable',
                 '--python', sdk['probe']['executable']]]
        else:
            # -I ignores PYTHONDONTWRITEBYTECODE; keep imports from mutating
            # the fingerprinted base SDK even during isolated manager calls.
            commands = [[sdk['probe']['executable'], '-I', '-B', '-m', 'venv', str(env_path)]]
            if value['manager'] == 'venv':
                commands[0].append('--without-pip')
            if value['dependency']:
                commands.append([str(executable), '-I', '-B', '-m', 'pip', '--isolated', 'install',
                                 '--require-hashes', '-r', value['dependency']])
        try:
            for command in commands:
                log = directory / ('command-' + str(len(receipt['commands'])) + '.log')
                # Stream output to disk; dependency installers can be verbose.
                with log.open('wb') as output:
                    result = run(command, cwd=cwd, env=env, stdout=output,
                                 stderr=subprocess.STDOUT, timeout=600)
                receipt['commands'].append(dict(arguments=command, exit_code=result.returncode, log=str(log)))
                write(receipt_file, receipt)
                if result.returncode:
                    raise ValueError('Python environment restoration failed; inspect ' + str(log))
            observed = environment_python.probe(executable, directory, run=run)
            verify_probe(observed, entry, env_path, sdk)
            receipt.update(state='complete', probe=observed)
            write(receipt_file, receipt)
        except Exception as error:
            receipt.update(state='failed', error=str(error)[:1000])
            write(receipt_file, receipt)
            raise
    observed = environment_python.probe(executable, directory, run=run)
    verify_probe(observed, entry, env_path, sdk)
    entry['executables'] = [str(executable)]
    entry['execution_environment'] = str(env_path)
    return receipt


def evidence_path(entry, observed, receipts):
    """Publication accepts an execution path only with its exact recipe receipt."""
    value = entry.get('restore_recipe')
    if not valid_recipe(value):
        return False
    found = [item for item in receipts if item.get('recipe_digest') == value['digest']]
    return (len(found) == 1 and found[0].get('state') == 'complete'
            and found[0].get('base_artifact') == value['base_artifact']
            and found[0].get('executable') == observed.get('path')
            and found[0].get('probe', {}).get('versions') == [entry['required']]
            and found[0].get('probe', {}).get('functionality', {}).get('prefix') == found[0].get('environment')
            and found[0].get('probe', {}).get('functionality', {}).get('base_prefix')
                == entry.get('artifact_receipt', {}).get('probe', {}).get('functionality', {}).get('prefix')
            and bool(found[0].get('commands'))
            and all(item.get('exit_code') == 0 for item in found[0]['commands']))


def automatic_check(item):
    return item['source'] == 'convention' and item['arguments'] == ['python', '-m', 'pytest']
