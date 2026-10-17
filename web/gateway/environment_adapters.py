"""SDK contracts shared by acquisition, adoption, activation and dispatch.

The registry owns ecosystem knowledge; workers own transactions and permissions.
An activation contract does not imply a trusted publisher installer. Node is the
first opt-in assisted adapter: its provenance remains an agent claim, while its
adopted bytes and contextual probes are independently recorded by the gateway.
"""
from dataclasses import dataclass
import json
from pathlib import Path
import re
import shutil
import tomllib


@dataclass(frozen=True)
class Adapter:
    capability: str
    executable: str
    commands: tuple
    inventory_arguments: tuple
    context_arguments: tuple
    version_pattern: str
    root_parents: int
    selection_files: tuple = ()
    companion: str = ''
    companion_pattern: str = r'([0-9]+\.[0-9]+\.[0-9]+)'
    resolver: object = None
    unpacker: object = None
    assisted: bool = False
    variables: tuple = ()
    version: int = 1
    dispatch_variables: tuple = ()

    def root(self, executable):
        return Path(executable).parents[self.root_parents]

    def environment(self, executable):
        return {key: value.format(root=self.root(executable), executable=executable)
                for key, value in self.variables}

    def command(self, executable, name):
        if name not in self.commands:
            raise ValueError('No approved command binding for ' + str(name))
        return str(Path(executable).with_name(name))


def dotnet(version, target, read, artifact):
    url = 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/' + '.'.join(version.split('.')[:2]) + '/releases.json'
    data = json.loads(read(url))
    candidates = []
    for release in data.get('releases', []):
        candidates.extend(release.get('sdks', []))
        if isinstance(release.get('sdk'), dict):
            candidates.append(release['sdk'])
    rid = 'linux-' + target['architecture']
    files = [item for sdk in candidates if sdk.get('version') == version
             for item in sdk.get('files', [])
             if item.get('rid') == rid and str(item.get('url', '')).endswith('.tar.gz')]
    if not files:
        raise ValueError(f'The publisher has no .NET SDK {version} artifact for {rid}.')
    item = files[0]
    return url, [artifact(item['url'], item.get('hash'), 'sha512', component='sdk')]


def rust(version, target, read, artifact):
    url = 'https://static.rust-lang.org/dist/channel-rust-' + version + '.toml'
    data = tomllib.loads(read(url).decode('utf-8'))
    triple = ('x86_64' if target['architecture'] == 'x64' else 'aarch64') + '-unknown-linux-gnu'
    archives = []
    for package in ('rustc', 'cargo', 'rust-std'):
        item = data.get('pkg', {}).get(package, {}).get('target', {}).get(triple, {})
        if not item.get('available'):
            raise ValueError(f'Rust {version} has no {package} artifact for {triple}.')
        archives.append(artifact(item.get('xz_url', ''), item.get('xz_hash'), 'sha256', component=package))
    return url, archives


def flat(archive, prefix, stage, index, remaining, unpack):
    return unpack(archive, prefix, remaining)


def rust_components(archive, prefix, stage, index, remaining, unpack):
    extracted = stage / f'unpacked-{index}'
    extracted.mkdir()
    total = unpack(archive, extracted, remaining)
    roots = list(extracted.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise ValueError('Rust distribution has an unsupported archive layout.')
    for component in (roots[0] / 'components').read_text(encoding='utf-8').splitlines():
        if not re.fullmatch(r'[A-Za-z0-9_-]+', component):
            raise ValueError('Rust distribution names an invalid component.')
        shutil.copytree(roots[0] / component, prefix, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('manifest.in'))
    return total


ADAPTERS = {
    'dotnet-sdk': Adapter('dotnet-sdk', 'dotnet', ('dotnet',), ('--list-sdks',), ('--version',),
        r'^([0-9]+\.[0-9]+\.[0-9]+)\s+\[', 0, ('global.json',), resolver=dotnet, unpacker=flat,
        variables=(('DOTNET_ROOT', '{root}'), ('DOTNET_MULTILEVEL_LOOKUP', '0')),
        dispatch_variables=(('DOTNET_ROOT', ''), ('DOTNET_MULTILEVEL_LOOKUP', '0'))),
    'rust-toolchain': Adapter('rust-toolchain', 'bin/rustc', ('rustc', 'cargo'), ('-Vv',), ('-Vv',),
        r'^release: ([0-9]+\.[0-9]+\.[0-9]+)$', 1, ('rust-toolchain', 'rust-toolchain.toml'),
        companion='cargo', companion_pattern=r'^cargo ([0-9]+\.[0-9]+\.[0-9]+)\b',
        resolver=rust, unpacker=rust_components, variables=(('RUSTC', '{executable}'),),
        dispatch_variables=(('RUSTC', ''),)),
    'node': Adapter('node', 'bin/node', ('node', 'npm'), ('--version',), ('--version',),
        r'^v([0-9]+\.[0-9]+\.[0-9]+)\s*$', 1, companion='npm', assisted=True),
}


def get(capability):
    adapter = ADAPTERS.get(capability)
    if adapter is None:
        raise ValueError('No SDK adapter exists for ' + str(capability))
    return adapter


def commands():
    return {command: adapter.capability for adapter in ADAPTERS.values() for command in adapter.commands}


def managed():
    return tuple(name for name, adapter in ADAPTERS.items() if adapter.resolver is not None)
