"""Adopt allocated SDK trees without trusting agent reports as verification.

An administrator's assisted-preparation permission authorizes running the
submitted binaries. Provenance is recorded as a claim, not publisher attestation.
Only descriptor-anchored regular files are copied to a new, content-addressed
snapshot; launch and validation recheck that snapshot before probing it. Agents
share the service account, so this is drift detection, not process confinement.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from urllib.parse import urlsplit

import dependency_constraints
import environment_adapters
import environment_artifacts
import environment_plan
import project_requirements
from project_access import open_project, open_directory

MAX_BYTES = 512 * 1024 * 1024
MAX_FILES = 20_000


def fingerprint(root, destination=None):
    """Hash/copy a pinned tree; reject links, special files and concurrent edits."""
    records, total = [], 0

    def walk(descriptor, relative, depth):
        nonlocal total
        if depth > 40:
            raise ValueError('The assisted SDK exceeds its directory depth budget.')
        with os.scandir(descriptor) as entries:
            names = []
            for entry in entries:
                names.append(entry.name)
                if len(names) + len(records) > MAX_FILES:
                    raise ValueError('The assisted SDK exceeds its file budget.')
        for name in sorted(names):
            path = relative / name
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                records.append([path.as_posix(), 'directory'])
                if destination:
                    (destination / path).mkdir()
                with open_directory(descriptor, name) as child:
                    walk(child, path, depth + 1)
            elif stat.S_ISREG(metadata.st_mode):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
                with os.fdopen(fd, 'rb') as source:
                    before = os.fstat(source.fileno())
                    if not stat.S_ISREG(before.st_mode) or before.st_ino != metadata.st_ino:
                        raise ValueError('The assisted SDK changed while it was being inspected.')
                    digest = hashlib.sha256()
                    output = (destination / path).open('xb') if destination else None
                    try:
                        while chunk := source.read(128 * 1024):
                            total += len(chunk)
                            if total > MAX_BYTES:
                                raise ValueError('The assisted SDK exceeds its byte budget.')
                            digest.update(chunk)
                            if output:
                                output.write(chunk)
                    finally:
                        if output:
                            output.close()
                    after = os.fstat(source.fileno())
                    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                        raise ValueError('The assisted SDK changed while it was being inspected.')
                mode = 0o755 if before.st_mode & 0o111 else 0o644
                if destination:
                    (destination / path).chmod(mode)
                records.append([path.as_posix(), mode, digest.hexdigest()])
            else:
                raise ValueError('Assisted SDKs must contain only regular files and directories; materialize symbolic links first.')
            if len(records) > MAX_FILES:
                raise ValueError('The assisted SDK exceeds its file budget.')
    with open_project(root, '.') as descriptor:
        walk(descriptor, Path('.'), 0)
    return hashlib.sha256(environment_plan.canonical(records).encode()).hexdigest()


def verify(specification):
    root = Path(specification['prefix'])
    if specification.get('adapter_version') != environment_adapters.get(specification['capability']).version:
        raise ValueError('The adopted SDK adapter contract changed; prepare again.')
    if fingerprint(root) != specification['tree_digest']:
        raise ValueError('The adopted SDK contents changed; prepare a new environment.')
    return root


def receipt(specification, store, cancelled=lambda: False):
    """Reuse only a snapshot allocated by this service, then independently probe."""
    root = Path(specification['prefix'])
    if root.parent != Path(store).absolute() / 'adopted':
        raise ValueError('The adopted SDK is outside the environment store.')
    if cancelled():
        raise ValueError('Assisted environment preparation was cancelled.')
    verify(specification)
    measured = environment_artifacts.probe(specification['capability'], root)
    if measured['versions'] != [specification['version']]:
        raise ValueError('The adopted SDK no longer reports its approved version.')
    verify(specification)
    return dict(artifact_id=environment_artifacts.identity(specification), specification=specification, probe=measured)


def acquire_provider(specification, store, *, fetch, verify=None, cancelled=lambda: False):
    return receipt(specification, store, cancelled=cancelled)


def verify_entry(entry):
    specification = entry.get('artifact_receipt', {}).get('specification') or entry.get('adoption')
    if not specification:
        raise ValueError('The adopted SDK receipt is missing; prepare again.')
    verify(specification)


def adopt(plan, result, allocation, store, authority, cancelled=lambda: False):
    """Return a new plan; an agent can neither overwrite the source nor approve it."""
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        raise ValueError('Assisted SDK adoption must run as an unprivileged service user.')
    if not isinstance(result, dict) or result.get('plan_digest') != plan['digest']:
        raise ValueError('The preparation result does not identify its exact source plan.')
    tools = result.get('tools')
    assisted = [(index, item) for index, item in enumerate(plan['requirements']) if item.get('preparation_method') == 'agent']
    if not isinstance(tools, list) or len(tools) != len(assisted):
        raise ValueError('Submit exactly one installation result for every assisted requirement.')
    found = {item.get('index'): item for item in tools if isinstance(item, dict) and type(item.get('index')) is int}
    if len(found) != len(tools) or set(found) != {index for index, _ in assisted}:
        raise ValueError('The preparation result contains duplicate or unknown requirements.')
    adopted = json.loads(json.dumps(plan))
    for index, item in assisted:
        if cancelled():
            raise ValueError('Assisted environment preparation was cancelled.')
        claim = found[index]
        provenance = claim.get('provenance')
        if (not isinstance(provenance, dict) or set(provenance) != {'source', 'method'}
                or not all(isinstance(value, str) and 0 < len(value) <= 2000 for value in provenance.values())):
            raise ValueError('Record the installation source and method; these remain agent claims.')
        source = urlsplit(provenance['source'])
        if source.scheme != 'https' or not source.hostname or source.username or source.password:
            raise ValueError('Record an HTTPS installation source without credentials.')
        adapter = environment_adapters.get(item['capability'])
        if not adapter.assisted:
            raise ValueError('No assisted activation contract exists for this capability.')
        incoming = Path(allocation) / f'sdk-{index}'
        parent = Path(store).absolute() / 'adopted'
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(prefix='.adopting-', dir=parent) as temporary:
            staged = Path(temporary) / 'sdk'
            staged.mkdir()
            digest = fingerprint(incoming, staged)
            if cancelled():
                raise ValueError('Assisted environment preparation was cancelled.')
            measured = environment_artifacts.probe(item['capability'], staged)
            version = measured['versions'][0]
            declarations = ([item['override']] if item.get('override') else item['evidence'])
            constraints = [declaration for entry in declarations
                           for declaration in project_requirements.declarations({'notation': item['notation'], **entry})]
            if not constraints or any(dependency_constraints.evaluate(value, version, notation) != 'satisfied'
                                      for value, notation in constraints):
                raise ValueError('The adopted SDK does not satisfy every recorded component declaration.')
            # Probes may populate caches. Those writes are not silently certified.
            if fingerprint(staged) != digest:
                raise ValueError('The assisted SDK probe modified its installation; use external caches.')
            specification = dict(provider='agent_adopted', capability=item['capability'], version=version, adapter_version=adapter.version,
                tree_digest=digest, provenance=dict(provenance, verification='agent_claim'), authority=authority)
            final = parent / environment_artifacts.identity(specification)
            if final.exists():
                if fingerprint(final) != digest:
                    raise ValueError('The existing adopted SDK failed its content integrity check.')
            else:
                staged.rename(final)
            specification['prefix'] = str(final)
        adopted['requirements'][index].update(state='acquire', version=version, artifact=specification,
            activation='available', activation_reason='', reason='Agent-prepared bytes adopted under explicit policy; provenance is an unverified claim.')
    adopted.update(parent_digest=plan['digest'], adoption_authority=authority, blockers=[])
    adopted['digest'] = environment_plan.digest(adopted)
    return adopted
