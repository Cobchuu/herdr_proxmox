"""Trusted acquisition strategies, including installers with final-path fixups.

Only this release-owned registry supplies executable hooks. A plan can select a
registered provider, never an import path or installer supplied by a repository.
Archive acquisition remains the default for older .NET/Rust specifications.
"""
from dataclasses import dataclass
from importlib import import_module


def invoke(reference, *arguments, **options):
    if callable(reference):
        return reference(*arguments, **options)
    module, name = reference.split(':', 1)
    return getattr(import_module(module), name)(*arguments, **options)


@dataclass(frozen=True)
class Provider:
    acquire: object
    select: object = None
    verify_entry: object = None


PROVIDERS = {
    'archive': Provider('environment_artifacts:acquire_archives'),
    'pinned_uv': Provider('environment_python:acquire_provider',
                          'environment_python:resolve_requirement', 'environment_python:verify_entry'),
    'agent_adopted': Provider('environment_adoption:acquire_provider',
                              verify_entry='environment_adoption:verify_entry'),
}


def get(name):
    if name not in PROVIDERS:
        raise ValueError('No registered environment provider exists for ' + str(name))
    return PROVIDERS[name]


def for_specification(specification):
    import environment_adapters
    adapter = environment_adapters.get(specification['capability'])
    name = specification.get('provider', 'archive')
    if name != adapter.provider and not (name == 'agent_adopted' and adapter.assisted):
        raise ValueError('The SDK provider is not declared by its capability adapter.')
    return get(name)


def resolve_requirement(item, target):
    import environment_adapters
    provider = get(environment_adapters.get(item['capability']).provider)
    if not provider.select:
        raise ValueError('This provider requires an exact archive SDK selection.')
    return invoke(provider.select, item, target)


def verify_entry(entry):
    import environment_adapters
    adapter = environment_adapters.get(entry['name'])
    receipt = entry.get('artifact_receipt') or {}
    specification = receipt.get('specification') or entry.get('adoption') or dict(provider=adapter.provider)
    provider = for_specification(dict(specification, capability=entry['name']))
    if provider.verify_entry:
        invoke(provider.verify_entry, entry)
