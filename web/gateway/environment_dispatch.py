"""One managed command dispatcher; choose an approved SDK by invocation cwd.

The dispatcher never downloads, guesses a version, or changes global defaults.
An explicit component is required outside known scopes. Receipts and native
validation still prove SDK correctness independently of interactive command use.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import sys

import environment_plan
import toolchain_policy

TOOLS = {'dotnet': 'dotnet-sdk', 'rustc': 'rust-toolchain', 'cargo': 'rust-toolchain'}


def choose(manifest, tool, cwd):
    capability = TOOLS.get(tool)
    if capability is None:
        raise ValueError('No managed dispatcher exists for ' + str(tool))
    root, cwd = Path(manifest['checkout']).resolve(), Path(cwd).resolve()
    if not cwd.is_relative_to(root):
        raise ValueError('Run this command inside its recorded component checkout.')
    matches = []
    for entry in manifest['toolchains']:
        component = PurePosixPath(entry['component'])
        if component.is_absolute() or '..' in component.parts:
            raise ValueError('A dispatch component escapes its checkout.')
        scope = root / Path(*component.parts)
        if entry['name'] == capability and cwd.is_relative_to(scope):
            matches.append((len(component.parts), entry))
    if not matches:
        raise ValueError('No approved component binding applies here; change to the component directory first.')
    depth = max(item[0] for item in matches)
    entries = [entry for size, entry in matches if size == depth]
    identities = {(entry['required'], tuple(entry['executables'])) for entry in entries}
    if len(identities) != 1:
        raise ValueError('This component has conflicting SDK bindings; resolve its declarations first.')
    return entries[0]


def install(policy, checkout, caches):
    root = Path(caches) / 'dispatch'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = dict(version=1, checkout=str(Path(checkout).absolute()), caches=str(Path(caches).absolute()),
                   plan_digest=policy['plan_digest'], toolchains=policy['toolchains'])
    encoded = environment_plan.canonical(payload)
    digest = hashlib.sha256(encoded.encode()).hexdigest()
    manifest = root / 'bindings.json'
    manifest.write_text(encoded, encoding='utf-8')
    for tool, capability in TOOLS.items():
        if not any(entry['name'] == capability for entry in policy['toolchains']):
            continue
        command = shlex.join([sys.executable, str(Path(__file__).absolute()), str(manifest), digest, tool])
        launcher = root / tool
        launcher.write_text('#!/bin/sh\nexec ' + command + ' "$@"\n', encoding='utf-8')
        launcher.chmod(0o700)
    return root, digest


def main(arguments):
    manifest_path, expected, tool, *forwarded = arguments
    with open(manifest_path, 'rb') as stream:
        encoded = stream.read(1_000_001)
    if len(encoded) > 1_000_000 or hashlib.sha256(encoded).hexdigest() != expected:
        raise ValueError('The recorded component dispatcher failed its integrity check.')
    manifest = json.loads(encoded)
    entry = choose(manifest, tool, Path.cwd())
    executable = entry['executables'][0]
    if tool == 'cargo':
        companions = [item for item in entry.get('companions', []) if item['name'] == 'cargo']
        if len(companions) != 1 or not companions[0].get('executables'):
            raise ValueError('The Rust component has no verified Cargo binding.')
        executable = companions[0]['executables'][0]
    environment = toolchain_policy.environment(dict(toolchains=[entry]))
    cache = Path(manifest['caches']) / hashlib.sha256(entry['component'].encode()).hexdigest()[:20]
    for name in ('cargo', 'dotnet'):
        (cache / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    environment.update(CARGO_HOME=str(cache / 'cargo'), DOTNET_CLI_HOME=str(cache / 'dotnet'))
    os.execve(executable, [executable, *forwarded], environment)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (ValueError, OSError) as error:
        print('Herdr environment: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
