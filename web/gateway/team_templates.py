"""Role presets and account-aware team planning. Never sends CLI prompts."""
import math
import re
import hashlib
import json

import model_catalog


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
    runtimes, warnings = {}, []
    for runtime in model_catalog.RUNTIMES:
        status = cli.status(runtime)
        if not status.get('installed') or cli.ready(runtime):
            continue
        if runtime in ('codex', 'claude') and status.get('status') != 'configured':
            continue
        if runtime == 'opencode':
            try:
                entry = model_catalog.discover_models(cli, projects, {'runtime': runtime, 'project': project})
            except ValueError:
                warnings.append('OpenCode model discovery failed; refresh models in the agent editor before using it for presets.')
                continue
            # The CLI enumerates configured providers, including environment and
            # project configuration. Stored credentials alone miss those cases.
            if entry.get('stale'):
                warnings.append('OpenCode catalog is stale; availability will be checked again at launch.')
            if not entry['models']:
                continue
        elif runtime == 'agy':
            entry = dict(model_catalog.curated(runtime), models=[dict(provider='', id='', name='CLI default', reasoning=[])])
            warnings.append('Antigravity uses its CLI model and account settings; verify its account in CLI accounts.')
        else:
            entry = model_catalog.curated(runtime)
        runtimes[runtime] = entry
    return dict(runtimes=runtimes, warnings=warnings)


def family(model):
    tokens = re.split(r'[-_.:/\s]+', model['id'].lower())
    if any(s in tokens for s in ('opus', 'astra', 'fable', 'max', 'pro')):
        return 'strong'
    if any(s in tokens for s in ('luna', 'haiku', 'mini', 'nano', 'flash', 'lite')):
        return 'economy'
    return 'standard'


def capability(model):
    tokens = re.split(r'[-_.:/\s]+', model['id'].lower())
    if any(t in tokens for t in ('opus', 'astra', 'fable', 'pro', 'max')):
        return 3
    if any(t in tokens for t in ('sonnet', 'sol', 'codex', 'coder', 'code', 'deepseek', 'qwen', 'glm', 'minimax', 'kimi')):
        return 2
    if any(t in tokens for t in ('luna', 'haiku', 'mini', 'nano', 'flash', 'lite')):
        return 1
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
    roles = body.get('template_roles', [])
    if (not isinstance(roles, list) or len(roles) > len(ROLES) or
            any(not isinstance(r, str) or r not in BY_ID for r in roles) or len(set(roles)) != len(roles)):
        raise ValueError('Choose distinct supported team role presets.')
    policy = body.get('model_policy', 'balanced')
    if not isinstance(policy, str) or policy not in POLICIES:
        raise ValueError('Choose a supported model policy.')
    preferences(body)
    return roles, policy


def plan(body, available):
    roles, policy = validate(body)
    members = []
    for role in ROLES:
        if role['id'] not in roles:
            continue
        manager = role['manager'] if role['manager'] in roles else ''
        reporting = 'Report to the Lead Developer.' if manager else 'Report directly to the organization owner.'
        members.append(dict(template_role=role['id'], name=role['name'], role=role['name'],
                            persona=role['persona'] + ' ' + reporting + '\n\n' + COMMON,
                            manager_role=manager, permission_mode='default', accessible_paths=[], use_worktree=True,
                            project=body.get('project', ''),
                            **selection(role, policy, available, preferences(body))))
    digest = hashlib.sha256(json.dumps([policy, members], sort_keys=True).encode()).hexdigest()
    return dict(members=members, warnings=available.get('warnings', []), model_policy=policy,
                runtime_preferences=preferences(body), template_plan=digest)


def snapshot():
    return dict(roles=[dict(role, minimum_capability=ROLE_MINIMUMS[role['id']], persona=role['persona'] + '\n\n' + COMMON)
                       for role in ROLES], policies=POLICIES, runtime_names=RUNTIME_NAMES)
