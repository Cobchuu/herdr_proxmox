"""Durable template workflow defaults; no agent launch or publication."""
from pathlib import Path

import project_git


def preview(project, projects, members):
    roles = {m['template_role'] for m in members}
    reviewers = [r for r in ('reviewer', 'qa_engineer') if r in roles]
    coordinator = 'integration_engineer' if 'integration_engineer' in roles else ''
    settings = dict(repository='', reviewer_roles=reviewers, coordinator_role=coordinator)
    notes = []
    if not reviewers and not coordinator:
        return settings, notes
    try:
        repository = Path(project_git.git(project, 'rev-parse', '--show-toplevel').strip()).resolve()
        common = Path(project_git.git(project, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()).resolve()
        if not repository.is_relative_to(projects) or not common.is_relative_to(projects):
            raise ValueError('Repository metadata is outside managed projects.')
        if repository != Path(project).resolve():
            raise ValueError('Select the repository root to connect task workflows.')
        settings['repository'] = repository.relative_to(projects).as_posix()
    except ValueError:
        notes.append('Review and integration workflow defaults require an accessible Git repository root. Members will still be created.')
        return settings, notes
    if reviewers:
        notes.append('New tasks receive an independent acceptance reviewer (Reviewer, then QA as fallback). Reviews run when a candidate is ready.')
    if coordinator:
        notes.append('Integration Engineer becomes the repository coordinator unless one is already configured. Automatic publishing, builds and SDK installation remain disabled.')
    return settings, notes


def organizations(store):
    reader = getattr(store, 'organization_records', None)
    values = reader() if callable(reader) else []
    return values if isinstance(values, list) else []


def coordinator_configurations(store):
    orgs = organizations(store)
    if not orgs:
        return []
    profiles = {p['id']: p for p in store.profile_records()}
    result = []
    for org in orgs:
        if org.get('removed_at'):
            continue
        settings = org.get('team_workflows') or {}
        if not isinstance(settings, dict):
            continue
        repository = settings.get('repository')
        coordinator_id = settings.get('coordinator_id')
        profile = profiles.get(coordinator_id) if isinstance(coordinator_id, str) else None
        if not isinstance(repository, str) or not repository or not profile:
            continue
        if profile.get('removed_at') or profile.get('archived') or profile.get('organization_id') != org['id']:
            continue
        path = (store.projects / repository).resolve()
        if not path.is_relative_to(store.projects) or Path(profile.get('project', '')).resolve() != path:
            continue
        result.append(dict(repository=repository, profile_id=profile['id'], organization_id=org['id'],
                           enabled=True, auto_build=False, auto_sdk=False, template_organization_id=org['id']))
    return result


def acceptance(store, organization_id, repository, assignee, profiles):
    org = next((o for o in organizations(store) if o.get('id') == organization_id and not o.get('removed_at')), {})
    settings = org.get('team_workflows') or {}
    if not isinstance(settings, dict) or not isinstance(settings.get('reviewer_ids'), list):
        return None
    for profile_id in settings['reviewer_ids']:
        profile = next((p for p in profiles if p.get('id') == profile_id), None)
        if (not profile or profile_id == assignee or profile.get('organization_id') != organization_id
                or profile.get('group_id') or profile.get('removed_at') or profile.get('archived')
                or not profile.get('use_worktree', True) or Path(profile.get('project', '')).resolve() != repository):
            continue
        return dict(reviewer_profile_id=profile_id, reviewer_name=profile.get('name', 'Reviewer'),
                    auto=True, state='waiting', source='organization_template')
    return None
