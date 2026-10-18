"""Role presets and account-aware team planning. Never sends CLI prompts."""
import math
import re
import hashlib
import json

import model_catalog
from permissions import permission_mode, accessible_paths
import template_resources


COMMON = (
    'Follow organization and project owner instructions. Work only on assigned tasks, '
    'respect repository conventions and the declared toolchain, and preserve unrelated work. '
    'Use your assigned worktree for changes. Report progress, blockers, changed files, actual '
    'checks and results to your manager; never claim unrun checks passed. Escalate scope, '
    'security, cost and architectural decisions to your manager or the organization owner. '
    'Coordinate through explicit Herdr delegation to existing members. Do not create additional '
    'agents or switch to a more expensive model without owner authorization. Do not push, '
    'publish, merge into shared branches or deploy without explicit authorization.'
)

ROLES = [
    dict(id='lead_developer', name='Lead Developer', manager='', tier='strong', persona=
         'Own technical planning and architecture. Turn owner goals into small, testable tasks '
         'with acceptance criteria; assign them to specialists and coordinate dependencies. '
         'Review tradeoffs and integration risks, request independent review, and summarize '
         'evidence and decisions for the owner. Delegate implementation where appropriate; '
         'do not treat prompt delivery or idle status as completed work.'),
    dict(id='frontend_developer', name='Frontend Developer', manager='lead_developer', tier='standard', persona=
         'Implement accessible, responsive interfaces using the existing design system. '
         'Handle loading, empty, error and keyboard states; agree API contracts with backend '
         'teammates. Verify the actual UI and relevant browser or component checks. Report '
         'visual and interaction limitations with reproduction steps.'),
    dict(id='backend_developer', name='Backend Developer', manager='lead_developer', tier='standard', persona=
         'Implement services, APIs and persistence with clear validation, authorization and '
         'error behavior. Preserve data integrity, concurrency guarantees and compatibility. '
         'Coordinate contracts with frontend teammates and verify failure paths, migrations '
         'and relevant service tests.'),
    dict(id='full_stack_developer', name='Full-stack Developer', manager='lead_developer', tier='standard', persona=
         'Deliver assigned features across UI, API and storage. Trace the complete user flow, '
         'keep contracts consistent, and make focused changes in established patterns. '
         'Verify both boundaries and end-to-end behavior, coordinating with specialists '
         'when work overlaps.'),
    dict(id='reviewer', name='Reviewer', manager='', tier='strong', persona=
         'Provide independent review against owner requirements and acceptance criteria. '
         'Inspect correctness, security, regressions and missing validation. Prioritize '
         'actionable findings with precise file locations, reproduction evidence and impact. '
         'Remain independent of the implementation lead: report acceptance risks to the '
         'organization owner. Review does not authorize merging or publication.'),
    dict(id='integration_engineer', name='Integration Engineer', manager='lead_developer', tier='strong', persona=
         'Assess compatibility of delivered commits, dependencies, API contracts and toolchains. '
         'Integrate only an explicitly authorized exact commit in your assigned checkout; '
         'preserve recovery state and resolve conflicts within scope. Run required build and '
         'integration checks, report actual evidence and escalate unresolved conflicts. '
         'Follow the Herdr worktree integration skill where available.'),
    dict(id='qa_engineer', name='QA Engineer', manager='', tier='standard', persona=
         'Translate acceptance criteria into risk-based verification. Reproduce defects, '
         'exercise user journeys and failure paths, and add meaningful regression coverage. '
         'Report release readiness and remaining gaps directly to the owner with reproducible '
         'evidence; do not approve work solely from an agent summary.'),
    dict(id='devops_engineer', name='DevOps Engineer', manager='lead_developer', tier='standard', persona=
         'Maintain reproducible CI, infrastructure configuration and observability. Plan '
         'deployment and rollback procedures, protect secrets and validate configuration '
         'changes. Report operational risks and request explicit owner authorization before '
         'production changes, destructive operations or deployment.'),
]
BY_ID = {role['id']: role for role in ROLES}
POLICIES = {'balanced': 'Balanced', 'economy': 'Lowest cost', 'capability': 'Higher capability'}
RUNTIME_NAMES = {'codex': 'Codex', 'claude': 'Claude Code', 'opencode': 'OpenCode', 'agy': 'Antigravity'}
# Compatibility floors are policy, not model benchmarks. Substantial coding,
# coordination and independent review should not silently use a light model.
ROLE_MINIMUMS = {r['id']: (1 if r['id'] == 'qa_engineer' else 2) for r in ROLES}
MAX_MEMBERS = 20
# Include escaped non-BMP characters, which can occupy a JSON surrogate pair.
# This larger budget is limited to authenticated team save/preview/library
# requests. Other requests retain their caps, including the 2 MB transfer limit.
MAX_REQUEST_BYTES = 12 * (MAX_MEMBERS * (6000 + 120 + 128 + 3 * 160 + 20 * 500 + 512) + 16000) + 65536
MEMBER_FIELDS = {'key', 'template_role', 'name', 'persona', 'runtime', 'provider', 'model', 'reasoning',
                 'manager_key', 'permission_mode', 'accessible_paths', 'use_worktree'}
BUNDLES = [
    dict(id='solo_developer', name='Solo developer', description='One full-stack member for small projects; the owner handles acceptance.',
         roles=['full_stack_developer']),
    dict(id='small_product', name='Small product team', description='A lead, a full-stack implementer and an independent reviewer.',
         roles=['lead_developer', 'full_stack_developer', 'reviewer']),
    dict(id='frontend_backend', name='Frontend/backend team', description='Separate frontend/backend specialists with leadership, review and integration.',
         roles=['lead_developer', 'frontend_developer', 'backend_developer', 'reviewer', 'integration_engineer']),
    dict(id='full_engineering', name='Full engineering team', description='All eight roles, including independent QA and DevOps.',
         roles=[r['id'] for r in ROLES]),
]
for bundle in BUNDLES:
    bundle.update(model_policy='balanced', version=1,
                  resource_limits=dict(max_active_sessions=max(2, min(4, len(bundle['roles']) + 1)),
                                       max_active_meetings=1, daily_session_cap=max(10, len(bundle['roles']) * 5)),
                  members=[dict(key=r, template_role=r) for r in bundle['roles']])
BY_BUNDLE = {b['id']: b for b in BUNDLES}


def expand(body):
    identifier = body.get('team_preset', '')
    if not isinstance(identifier, str) or identifier and identifier not in BY_BUNDLE:
        raise ValueError('Choose a supported team preset.')
    if not identifier:
        return dict(body)
    bundle = BY_BUNDLE[identifier]
    result = {'model_policy': bundle['model_policy'], 'resource_limits': bundle['resource_limits'], **body}
    if 'template_roles' not in body and 'team_members' not in body:
        result.update(template_roles=list(bundle['roles']), team_members=[dict(s) for s in bundle['members']])
    return result


def member_specs(body):
    supplied = body.get('team_members')
    if supplied is None and 'team_members' not in body:
        return [dict(key=role['id'], template_role=role['id']) for role in ROLES
                if role['id'] in body.get('template_roles', [])]
    if not isinstance(supplied, list) or len(supplied) > MAX_MEMBERS:
        raise ValueError(f'Choose up to {MAX_MEMBERS} team members.')
    result, keys = [], set()
    for spec in supplied:
        if not isinstance(spec, dict) or set(spec) - MEMBER_FIELDS:
            raise ValueError('Invalid member customization fields.')
        key, role = spec.get('key'), spec.get('template_role')
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', key) or key in keys:
            raise ValueError('Member draft IDs must be distinct valid identifiers.')
        if not isinstance(role, str) or role not in BY_ID:
            raise ValueError('Choose a supported member role.')
        keys.add(key)
        result.append(dict(spec))
    return result


def member_text(spec, key, fallback, limit):
    value = spec.get(key, fallback)
    if not isinstance(value, str) or not value.strip() or len(value) > limit or '\x00' in value:
        raise ValueError(f'Invalid member {key} (maximum {limit} characters).')
    return value.strip()


def member_selection(spec, role, policy, available, preferred):
    runtime = spec.get('runtime', '')
    if not isinstance(runtime, str) or runtime and runtime not in RUNTIME_NAMES:
        raise ValueError('Choose a supported member CLI.')
    filtered = available
    if runtime:
        if runtime not in available['runtimes']:
            raise ValueError(f'{RUNTIME_NAMES[runtime]} is unavailable for this member.')
        filtered = dict(available, runtimes={runtime: available['runtimes'][runtime]})
    if spec.get('model'):
        if not runtime or runtime == 'agy':
            raise ValueError('Select a member CLI before overriding its model; Antigravity uses CLI defaults.')
        entry = filtered['runtimes'][runtime]
        provider = '' if runtime == 'claude' and spec.get('provider') == 'anthropic' else spec.get('provider', '')
        chosen = next((m for m in entry['models'] if m['id'] == spec['model'] and
                       m.get('provider', '') == provider), None)
        if chosen is None or not suitable(role, chosen, runtime):
            raise ValueError('The overridden member model is unavailable or below the role capability minimum.')
        filtered = dict(available, runtimes={runtime: dict(entry, models=[chosen])})
    elif spec.get('provider'):
        raise ValueError('Select a model with the overridden provider.')
    selected = selection(role, policy, filtered, [runtime] if runtime else preferred)
    if runtime or spec.get('model'):
        selected['selection_note'] += ' Member CLI/model override applied.'
    if 'reasoning' in spec:
        effort = spec['reasoning']
        entry = filtered['runtimes'][selected['runtime']]
        chosen = next(m for m in entry['models'] if m['id'] == selected['model'] and m.get('provider', '') == selected['provider'])
        if (not isinstance(effort, str) or effort and
                (effort not in chosen.get('reasoning', []) or selected['runtime'] == 'opencode' and not entry.get('supports_variants'))):
            raise ValueError('The overridden reasoning effort is unavailable for this member model.')
        selected['reasoning'] = effort
    return selected


def preferences(body):
    values = body.get('runtime_preferences', [])
    if (not isinstance(values, list) or len(values) > 4 or
            any(not isinstance(v, str) or v not in RUNTIME_NAMES for v in values) or len(set(values)) != len(values)):
        raise ValueError('Choose distinct supported preferred CLIs.')
    return values


def price(model):
    cost = model.get('cost')
    if not isinstance(cost, dict):
        return None
    values = [cost.get(k) for k in ('input', 'output')]
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for v in values):
        return None
    return sum(values)


def is_free(model):
    known = price(model)
    if known is not None:
        return known == 0
    # Incomplete positive pricing still overrides an apparent free model ID.
    cost = model.get('cost')
    if isinstance(cost, dict) and any(isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0
                                      for v in (cost.get('input'), cost.get('output'))):
        return False
    return bool(re.search(r'(?:^|[-:/])free$', model['id'].lower()))


def catalog(cli, projects, project):
    runtimes, warnings, accounts = {}, [], []
    for runtime in model_catalog.RUNTIMES:
        account = dict(runtime=runtime, name=RUNTIME_NAMES[runtime], available=False, model_count=0)
        accounts.append(account)
        status = cli.status(runtime)
        if not status.get('installed'):
            account['reason'] = 'CLI is not installed.'
            continue
        problem = cli.ready(runtime)
        if problem:
            account['reason'] = str(problem)[:500]
            continue
        if runtime in ('codex', 'claude') and status.get('status') != 'configured':
            account['reason'] = ('Account is not signed in.' if status.get('status') == 'not_configured'
                                 else 'Sign-in status could not be determined. Inspect CLI accounts.')
            continue
        if runtime == 'opencode':
            try:
                entry = model_catalog.discover_models(cli, projects, {'runtime': runtime, 'project': project})
            except ValueError:
                account['reason'] = 'Model discovery failed. Refresh OpenCode models and inspect CLI accounts.'
                warnings.append('OpenCode model discovery failed; refresh models in the agent editor before using it for presets.')
                continue
            # The CLI enumerates configured providers, including environment and
            # project configuration. Stored credentials alone miss those cases.
            if entry.get('stale'):
                warnings.append('OpenCode catalog is stale; availability will be checked again at launch.')
            if not entry['models']:
                account['reason'] = 'No models were returned for the configured providers.'
                continue
        elif runtime == 'agy':
            entry = dict(model_catalog.curated(runtime), models=[dict(provider='', id='', name='CLI default', reasoning=[])])
            warnings.append('Antigravity uses its CLI model and account settings; verify its account in CLI accounts.')
        else:
            entry = model_catalog.curated(runtime)
        runtimes[runtime] = entry
        account.update(available=True, model_count=len(entry['models']),
                       reason='CLI-managed model/account; sign-in cannot be verified here.' if runtime == 'agy'
                       else 'Available catalog; provider entitlements and quotas are not verified.' if runtime == 'opencode'
                       else 'CLI reports signed in; individual model entitlements are not verified.')
    return dict(runtimes=runtimes, warnings=warnings, accounts=accounts)


def capability(model):
    tokens = re.split(r'[-_.:/\s]+', model['id'].lower())
    if any(t in tokens for t in ('luna', 'haiku', 'mini', 'nano', 'flash', 'lite')):
        return 1
    if any(t in tokens for t in ('opus', 'astra', 'fable', 'pro', 'max')):
        return 3
    if any(t in tokens for t in ('sonnet', 'sol', 'codex', 'coder', 'code', 'deepseek', 'qwen', 'glm', 'minimax', 'kimi')):
        return 2
    context = model.get('context')
    if model.get('tool_call') is True and type(context) is int:
        return 2 if context >= 64000 else 1 if context >= 16000 else 0
    return 0


def suitable(role, model, runtime):
    if runtime == 'agy':
        return True  # The CLI-managed choice is explicitly unverified in preview.
    floor = ROLE_MINIMUMS[role['id']]
    context = model.get('context')
    return (model.get('tool_call') is not False and capability(model) >= floor
            and (context is None or type(context) is int and context >= (16000 if floor == 1 else 32000)))


def selection(role, policy, available, preferred=()):
    minimum = ROLE_MINIMUMS[role['id']]
    target = 3 if policy == 'capability' and role['tier'] == 'strong' else minimum
    candidates = []
    for runtime, entry in available['runtimes'].items():
        for index, model in enumerate(entry['models']):
            if not suitable(role, model, runtime):
                continue
            if runtime == 'agy':
                rank = (9, 9, 9, 9, 9)
            else:
                free, known = is_free(model), price(model)
                fit = abs(capability(model) - target)
                preference = preferred.index(runtime) if runtime in preferred else len(preferred)
                if policy == 'economy':
                    rank = (0 if free else 1, preference, known if known is not None else float('inf'), fit, index)
                else:
                    rank = (fit, 0 if free else 1, preference, known if known is not None else float('inf'), index)
            candidates.append((rank, runtime, model, entry))
    if not candidates:
        raise ValueError(f"No ready CLI account/model meets the {role['name']} capability requirements. Connect a suitable CLI/model and its Herdr integration first.")
    _, runtime, model, entry = min(candidates, key=lambda c: (c[0], c[1], c[2]['id']))
    effort = 'high' if role['tier'] == 'strong' else 'medium'
    supported = model.get('reasoning', [])
    reasoning = effort if effort in supported and (runtime != 'opencode' or entry.get('supports_variants')) else ''
    note = ('Free according to catalog pricing/model ID; availability and quotas can change.' if is_free(model)
            else 'CLI-managed model and billing.' if runtime == 'agy'
            else 'Model family chosen for role and cost policy; account pricing and limits are not verified.')
    if runtime != 'agy':
        note += f' Role minimum: {minimum}; selected capability tier: {capability(model)} (policy heuristic).'
        note += (' Context: ' + str(model['context']) + ' tokens.' if model.get('context') else ' Context capacity is not reported.')
        if preferred and runtime not in preferred:
            note += ' Preferred CLI was unavailable or a better eligible model was selected.'
    return dict(runtime=runtime, provider=model.get('provider', ''), model=model['id'], reasoning=reasoning,
                model_name=model.get('name', model['id']), selection_note=note)


def validate(body):
    body = expand(body)
    roles = body.get('template_roles', [])
    if (not isinstance(roles, list) or len(roles) > len(ROLES) or
            any(not isinstance(r, str) or r not in BY_ID for r in roles) or len(set(roles)) != len(roles)):
        raise ValueError('Choose distinct supported team role presets.')
    policy = body.get('model_policy', 'balanced')
    if not isinstance(policy, str) or policy not in POLICIES:
        raise ValueError('Choose a supported model policy.')
    preferences(body)
    template_resources.validate(body.get('resource_limits'))
    if 'team_members' in body:
        specs = member_specs(body)
        derived = list(dict.fromkeys(s['template_role'] for s in specs))
        if 'template_roles' in body and set(roles) != set(derived):
            raise ValueError('Selected roles must match the customized member roster.')
        roles = derived
    return roles, policy


def plan(body, available):
    body = expand(body)
    roles, policy = validate(body)
    specs = member_specs(dict(body, template_roles=roles))
    lead = next((s['key'] for s in specs if s['template_role'] == 'lead_developer'), '')
    names, managers, counts = {}, {}, {}
    for spec in specs:
        role = BY_ID[spec['template_role']]
        counts[role['id']] = counts.get(role['id'], 0) + 1
        suffix = ' ' + str(counts[role['id']]) if counts[role['id']] > 1 else ''
        names[spec['key']] = member_text(spec, 'name', role['name'] + suffix, 120)
        default_manager = lead if role['manager'] and lead != spec['key'] else ''
        manager = spec.get('manager_key', default_manager)
        if not isinstance(manager, str):
            raise ValueError('Invalid member manager.')
        managers[spec['key']] = manager
    for key in managers:
        visited, current = {key}, managers[key]
        while current:
            if current not in managers:
                raise ValueError('Member manager must be part of this team.')
            if current in visited:
                raise ValueError('Manager relationships cannot contain cycles.')
            visited.add(current)
            current = managers[current]
    members = []
    for spec in specs:
        role = BY_ID[spec['template_role']]
        manager = managers[spec['key']]
        reporting = 'Report to ' + names[manager] + '.' if manager else 'Report directly to the organization owner.'
        chosen = member_selection(spec, role, policy, available, preferences(body))
        worktree = spec.get('use_worktree', True)
        if not isinstance(worktree, bool):
            raise ValueError('Use worktree must be true or false.')
        members.append(dict(template_role=role['id'], template_key=spec['key'], name=names[spec['key']], role=role['name'],
                            persona=member_text(spec, 'persona', role['persona'], 6000) + ' ' + reporting + '\n\n' + COMMON,
                            persona_instruction=member_text(spec, 'persona', role['persona'], 6000),
                            manager_key=manager, manager_role=BY_ID[next(s['template_role'] for s in specs if s['key'] == manager)]['id'] if manager else '',
                            manager_name=names.get(manager, 'Organization owner'),
                            permission_mode=permission_mode(spec, chosen['runtime']),
                            accessible_paths=accessible_paths(spec, chosen['runtime']), use_worktree=worktree,
                            project=body.get('project', ''),
                            **chosen))
    digest = hashlib.sha256(json.dumps([policy, members], sort_keys=True).encode()).hexdigest()
    return dict(members=members, warnings=available.get('warnings', []), model_policy=policy,
                runtime_preferences=preferences(body), resource_limits=template_resources.validate(body.get('resource_limits')),
                team_preset=body.get('team_preset', ''),
                accounts=available.get('accounts', []), template_plan=digest, member_specs=specs, runtimes=available['runtimes'])


def snapshot():
    return dict(roles=[dict(role, minimum_capability=ROLE_MINIMUMS[role['id']], persona_instruction=role['persona'],
                           persona=role['persona'] + '\n\n' + COMMON) for role in ROLES],
                policies=POLICIES, runtime_names=RUNTIME_NAMES, max_members=MAX_MEMBERS, bundles=BUNDLES,
                resource_defaults=template_resources.DEFAULTS, resource_ranges=template_resources.RANGES)
