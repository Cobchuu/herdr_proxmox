"""What Herdr can prepare, declared per ecosystem instead of assumed.

A recognised language is not a prepared capability. Discovery finds requirements;
this module states which of them Herdr can actually satisfy on this host, and
which of those operations exist at all. Support is advertised per ecosystem,
platform and operation, because one universal "supported" flag is exactly the
claim this design exists to refuse: a project that needs a Rust toolchain and a
.NET SDK are different capabilities with different providers, and a capability
that cannot be acquired here must say so rather than appear as a green check.

Three things are deliberately kept apart:

* **the ecosystem registry** (`project_requirements.ECOSYSTEMS`) knows how to read
  a repository. It is evidence, not authority.
* **the release catalog** (`install/toolchains.json`) names installers the deployed
  release ships. It is release capability, not project intent.
* **this module** joins the two for one requirement and says what can be done
  with it here: resolve an installed version, acquire an exact one, or refuse.

Nothing here executes a command, downloads anything, or reads a project file.
Every operation is a declared capability, not a claim that a recipe exists.
"""
import platform
import re
import sys

import toolchain_policy

# The operations an adapter may advertise, in the order the pipeline uses them.
# A requirement that only supports some of these is still usable; it simply
# cannot be prepared automatically, and the plan says which step is missing.
OPERATIONS = ('detect', 'resolve', 'acquire', 'activate', 'verify', 'restore', 'check')

# Capability ids, separate from the command that provides them. `python3` can
# provide Python; `rustc` is not an executable named `rust-toolchain`. A
# requirement's `tool` is a command name in the discovery registry, so the
# mapping from command to capability is declared here rather than inferred.
CAPABILITY_IDS = {
    'node': 'node',
    'python': 'python',
    'php': 'php',
    'go': 'go',
    'rust': 'rust-toolchain',
    'rust-toolchain': 'rust-toolchain',
    'dotnet': 'dotnet-sdk',
    'dart': 'dart-sdk',
    'flutter': 'flutter-sdk',
}

# Command spellings per capability. Debian commonly ships `python3` without a
# `python` alias, and a requirement names a capability rather than a binary, so
# both spellings are probed and reported rather than declared absent.
PROVIDERS = {
    'python': ('python3', 'python'),
    'rust-toolchain': ('rustc',),
    'dotnet-sdk': ('dotnet',),
    'dart-sdk': ('dart',),
    'flutter-sdk': ('flutter',),
}

# Capabilities a managed acquisition and activation adapter exists for, on the
# executors environment_artifacts accepts. This is the one place the answer
# lives: a plan built without preparation still has to say whether preparing
# could ever produce a binding, and telling an operator a capability has no
# adapter when one exists would stop them from being helped at all.
MANAGED = ('dotnet-sdk', 'rust-toolchain')

# Base discovery/probe capabilities. Recognition alone never implies an
# installer, dependency restore or a check recipe: MANAGED above is the only
# claim that one exists, and describe() reports it alongside these.
CAPABILITIES = {
    'node': dict(label='Node.js', ecosystems=('node',),
                 operations=('detect', 'resolve', 'verify'),
                 platforms=('linux', 'macos', 'windows'),
                 reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'python': dict(label='Python', ecosystems=('python',),
                   operations=('detect', 'resolve', 'verify'),
                   platforms=('linux', 'macos', 'windows'),
                   reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'php': dict(label='PHP', ecosystems=('php',),
                operations=('detect', 'resolve', 'verify'),
                platforms=('linux', 'macos', 'windows'),
                reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'go': dict(label='Go', ecosystems=('go',),
               operations=('detect', 'resolve', 'verify'),
               platforms=('linux', 'macos', 'windows'),
               reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'rust-toolchain': dict(label='Rust toolchain', ecosystems=('rust',),
                           operations=('detect', 'resolve', 'verify'),
                           platforms=('linux', 'macos', 'windows'),
                           reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'dotnet-sdk': dict(label='.NET SDK', ecosystems=('dotnet',),
                       operations=('detect', 'resolve', 'verify'),
                       platforms=('linux', 'macos', 'windows'),
                       reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'dart-sdk': dict(label='Dart SDK', ecosystems=('dart',),
                     operations=('detect', 'resolve', 'verify'),
                     platforms=('linux', 'macos', 'windows'),
                     reason='Resolved and verified on PATH; no trusted installer ships yet.'),
    'flutter-sdk': dict(label='Flutter SDK', ecosystems=('dart',),
                        operations=('detect', 'resolve', 'verify'),
                        platforms=('linux', 'macos', 'windows'),
                        reason='Resolved and verified on PATH; no trusted installer ships yet.'),
}

PLATFORMS = {'linux': sys.platform.startswith('linux'),
             'darwin': sys.platform == 'darwin',
             'macos': sys.platform == 'darwin',
             'win32': sys.platform.startswith('win'),
             'windows': sys.platform.startswith('win')}

VERSION = re.compile(r'\d+(?:\.\d+)+')


def host():
    """The executor this gateway runs on, as the plan records it."""
    return dict(platform=sys.platform, machine=platform.machine() or 'unknown',
                python=platform.python_version())


def supported(platform_name=None):
    return PLATFORMS.get(platform_name or sys.platform, False)


def capability_for(tool):
    """The capability id a requirement's tool name maps to.

    An unregistered tool is returned unchanged so the plan can report the gap
    instead of silently dropping the requirement.
    """
    if not isinstance(tool, str) or not tool:
        return ''
    return CAPABILITY_IDS.get(tool, tool)


def providers(capability):
    """Command spellings that can provide a capability."""
    return PROVIDERS.get(capability, (capability,))


def registry(capability):
    """The declared record for a capability, or a precise absence."""
    entry = CAPABILITIES.get(capability)
    if entry is None:
        return None
    entry = dict(entry, id=capability, providers=list(providers(capability)))
    entry['acquirable'] = 'acquire' in entry['operations']
    entry['managed'] = capability in MANAGED
    entry['supported'] = any(supported(name) for name in entry['platforms'])
    if entry['managed']:
        import environment_artifacts
        try:
            environment_artifacts.host_target()
            entry['operations'] = (*entry['operations'], 'acquire', 'activate', 'check')
            entry['acquirable'] = True
            entry['reason'] = 'Exact SDK preparation and explicitly approved component checks are available; automatic task preparation/resume is separate.'
        except ValueError as error:
            entry['activation_reason'] = str(error)
    return entry


def release_catalog(path=None):
    """Toolchains the deployed release can install, and the version each pins.

    The release reads its own repository declaration (`.fvmrc` for Flutter), not
    a managed project's, so each entry is one exact version for the release
    itself. That is release capability, and it is deliberately kept out of the
    capability registry: a project may need a version the release does not ship.
    """
    catalog = toolchain_policy.catalog(path) if path else toolchain_policy.catalog()
    entries = {}
    for name, entry in sorted(catalog.items()):
        if not isinstance(entry, dict):
            continue
        root = (toolchain_policy.CATALOG if path is None else path).parent.parent
        version, declared_by = toolchain_policy.declared_version(entry, root)
        if version is None:
            # A catalog entry with no usable declaration installs nothing, and
            # saying so is more useful than advertising an unpinned installer.
            entries[name] = dict(label=str(entry.get('label') or name), version='',
                                 declared_by='', script='', acquirable=False,
                                 reason='This release declares no version for the toolchain.')
            continue
        entries[name] = dict(label=str(entry.get('label') or name), version=version,
                             declared_by=declared_by or '',
                             script=str(entry.get('script') or ''), acquirable=True,
                             reason='')
    return entries


def release_exact(tool, entries=None):
    """The exact version the release would install for a capability, if any."""
    entries = release_catalog() if entries is None else entries
    entry = entries.get(tool)
    if not entry or not entry.get('acquirable') or not VERSION.fullmatch(str(entry.get('version') or '')):
        return None
    return entry['version']


def describe(tool):
    """What can be done for one requirement's tool on this host.

    The result is always an explicit record. An unknown capability is reported as
    unknown rather than as an empty capability that would read as support.
    """
    capability = capability_for(tool)
    entry = registry(capability)
    if entry is None:
        return dict(id=capability, tool=tool, label=tool, known=False, acquirable=False,
                    operations=(), providers=list(providers(capability)), supported=supported(),
                    reason=f'No adapter is registered for {capability}; Herdr cannot prepare it here.')
    return dict(entry, tool=tool, known=True,
                reason=entry['reason'] if entry['supported'] else
                f"{entry['label']} is not advertised for {sys.platform}.")


def for_ecosystem(ecosystem_id):
    """Every capability the registry declares for an ecosystem id."""
    return [entry for entry in (registry(name) for name in sorted(CAPABILITIES))
            if entry and ecosystem_id in entry['ecosystems']]
