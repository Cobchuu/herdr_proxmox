"""Bounded check proposals; discovery proposes, an administrator selects.

No repository command executes while planning. Native recipes remain proposals
even when conventional, and their arguments/cwd are frozen before validation.
"""
from pathlib import PurePosixPath


def candidates(report, paths):
    result = []
    paths = set(paths)
    for component in report.get('components', []):
        directory = component['path']
        for index, proposal in enumerate(component.get('candidate_commands', [])):
            arguments = list(proposal['command'])
            if arguments[0] == 'dotnet':
                projects = sorted(name for name in paths if PurePosixPath(name).parent.as_posix() == directory
                    and name.endswith(('.sln', '.slnx', '.csproj', '.fsproj', '.vbproj')))
                solutions = [name for name in projects if name.endswith(('.sln', '.slnx'))]
                projects = solutions or projects
                if len(projects) != 1:
                    continue  # No guessed invocation when a directory has competing entry points.
                arguments.append(PurePosixPath(projects[0]).name)
            result.append(dict(id=f'{directory}:{index}:{proposal["purpose"]}', cwd=directory,
                arguments=arguments, source=proposal['source'], purpose=proposal['purpose']))
    return result[:100]


def select(plan, identifiers, actor):
    if (not isinstance(identifiers, list) or len(identifiers) > 20
            or any(not isinstance(value, str) for value in identifiers)
            or len(set(identifiers)) != len(identifiers)):
        raise ValueError('Select up to 20 distinct proposed check identities.')
    proposals = {item['id']: item for item in plan.get('check_candidates', [])}
    if set(identifiers) - proposals.keys():
        raise ValueError('A selected check is not a proposal in this committed plan.')
    return [dict(proposals[identifier], selected_by=actor) for identifier in identifiers]


def automatic(plan):
    """Only named build/test entry points, under separate project-code permission."""
    found = []
    for item in plan.get('check_candidates', []):
        arguments = item['arguments']
        conventional = (item['source'] == 'convention' and arguments[0] in ('dotnet', 'cargo')
                        and len(arguments) in (2, 3) and arguments[1] in ('build', 'test'))
        node = (item['source'] == 'package.json#scripts' and arguments in (
            ['npm', 'run', 'build'], ['npm', 'run', 'test']))
        if conventional or node:
            found.append(item['id'])
    return found[:20]
