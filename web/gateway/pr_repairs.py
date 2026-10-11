"""Explicit, durable conflict repairs on an existing task and PR branch."""
from pathlib import Path
import hashlib
import uuid

import project_git
from herdr_errors import HerdrError
from repository_lock import repository_lock
from session_ownership import reserves

ACTIVE = ('queued', 'preparing', 'starting', 'running', 'waiting_for_input', 'monitoring_unavailable', 'validating', 'validation_failed', 'needs_attention')
READ_FAILURE_LIMIT = 3
# Finished attempts that must not trap the task. `validation_failed` stays in
# ACTIVE so publication remains blocked, but the operator must be able to ask
# for a fresh repair instead of being left with only an inspection button.
RETRYABLE = ('validation_failed',)


def active(task):
    return (task.get('pr_repair') or {}).get('state') in ACTIVE


def save(service, task, action):
    # Waiting and working are sampled repeatedly. Record transitions, not every
    # poll, so the activity history stays useful during a long agent turn.
    # The monitoring counters must still persist to accumulate, so they are not
    # excluded here: an outage does add an entry per failed read, which is the
    # price of counting consecutive failures.
    if service.comparable(service.get(task['id'])) == service.comparable(task):
        return task
    return service.save(task, action, 'pr_repair_scheduler')


def refresh_pull(service, task):
    """Refresh and record GitHub facts on task; the caller persists that task."""
    pull = service.github.request('/repos/' + task['github_repository'] + '/pulls/' + str(task['pull']['number']))
    service.record_pull(task, pull)
    if task['state'] in ('merged', 'closed', 'completed') or pull.get('state') != 'open':
        raise ValueError('Only an open pull request can be repaired.')
    return pull


def request(service, task, body, actor):
    from contributions import SHA, stamp
    if body.get('mode') not in (None, 'cancel', 'retry'):
        raise ValueError('Choose conflict repair, cancellation or an inspected recheck.')
    if body.get('mode') == 'retry':
        if (task.get('pr_repair') or {}).get('state') != 'needs_attention' or body.get('inspected') is not True:
            raise ValueError('Inspect the repair session before rechecking it.')
        previous = task['pr_repair']
        run = next((j for j in service.store.snapshot(live_status=False)['jobs'] if j['id'] == task.get('run_id')), {})
        if previous.get('started_at') or run.get('session_request_id') == 'pr-repair-' + previous['id']:
            previous.update(state='queued', message='Rechecking the inspected repair; existing delivery will be adopted.')
            return service.save(task, 'pr_repair_recheck', actor)
        previous['state'] = 'obsolete'
        body = dict(body, head_sha=task.get('head_sha'))
    if body.get('mode') == 'cancel':
        if (task.get('pr_repair') or {}).get('state') != 'queued':
            raise ValueError('Only a queued, undispatched repair can be cancelled.')
        repair = task['pr_repair']
        runs = service.store.snapshot(live_status=False)['jobs']
        if repair.get('started_at') or any(
                run.get('session_request_id') == 'pr-repair-' + repair['id'] for run in runs):
            raise ValueError('This repair was already submitted; inspect its session instead of cancelling its queue.')
        task['pr_repair'].update(state='cancelled', message='Queued repair cancelled.', at=stamp())
        return service.save(task, 'pr_repair_cancelled', actor)
    if active(task) and (task.get('pr_repair') or {}).get('state') not in RETRYABLE:
        # Response-only feedback: preserve progress and avoid audit noise.
        return dict(task, action_message='A conflict repair is already in progress. No second execution was started.')
    if not task.get('pull') or not task.get('publish'):
        raise ValueError('Publish and open the pull request before requesting conflict repair.')
    pull = refresh_pull(service, task)
    head, base = pull['head']['sha'], pull['base'].get('sha')
    if pull.get('mergeable') is not False:
        raise ValueError('GitHub has not confirmed merge conflicts. Refresh PR status first.')
    if (body.get('head_sha') != head or head != task.get('head_sha')
            or head != task['publish'].get('head_sha') or not SHA.fullmatch(str(base))):
        raise ValueError('The PR candidate or base changed; refresh and review the current conflict first.')
    profile = next((p for p in service.store.snapshot(live_status=False)['profiles']
                    if p['id'] == task['profile_id'] and not p.get('archived')), None)
    if not profile or profile.get('ephemeral') or profile.get('group_id') or not profile.get('use_worktree', True):
        raise ValueError('Conflict repair requires an assigned persistent worktree agent.')
    history = list(task.get('pr_repair_history') or [])
    if task.get('pr_repair'):
        history.append(task['pr_repair'])
    task['pr_repair_history'] = history[-20:]
    task['pr_repair'] = dict(id=uuid.uuid4().hex, state='queued', head_sha=head, upstream_sha=base,
                             previous_base=task['base_sha'], actor=actor, requested_at=stamp(),
                             message='Queued for the assigned agent; other work is not interrupted.')
    return service.save(task, 'pr_repair_queued', actor)


def instructions(task):
    repair = task['pr_repair']
    procedure = (Path(__file__).parent / 'skills/herdr-worktree-integration/references/merge.md').resolve().as_posix()
    return (f"Resolve merge conflicts in existing PR #{task['pull']['number']} for {task['github_repository']}. "
            f"Work only on assigned branch {task['branch']} in this checkout. Starting published commit: {repair['head_sha']}. "
            f"Merge EXACT upstream commit {repair['upstream_sha']} using git -c user.name=Herdr-Agent "
            '-c user.email=agent@herdr.local merge --no-edit. '
            f"Pinned recovery: {repair['recovery']['ref']}. Read and follow {procedure} before mutation. "
            'Before starting the merge, verify that HEAD equals the supplied starting commit and the checkout is clean. '
            'Preserve both upstream changes and the original task behavior. Do not rebase, reset, stash, discard unrelated '
            'work, force-push, push, open another PR, merge the PR, update the shared checkout or deploy. '
            'If a product decision is required, stop and report it. Resolve conflicts, commit locally, verify both '
            'supplied commits are ancestors of HEAD, and run the task required checks. '
            'Use git -c user.name=Herdr-Agent -c user.email=agent@herdr.local commit. '
            'Write the completion receipt LAST to {{HERDR_TASK_RECEIPT}} with outcome=complete, commit=full HEAD SHA, '
            'run_id={{HERDR_TASK_RUN}}, token={{HERDR_TASK_TOKEN}}, and tests as an array of actual check results. '
            'Missing or failed checks must be reported honestly. Publication requires dashboard approval.\n\n'
            + task['title'] + '\nOriginal task and acceptance criteria:\n' + task['description'])


def dispatch(service, task):
    from contributions import MAX_ACTIVE_EXECUTIONS, stamp
    repair = task['pr_repair']
    request_id = 'pr-repair-' + repair['id']
    jobs = service.store.snapshot(live_status=False).get('jobs', [])
    run = next((j for j in jobs if j['id'] == task.get('run_id')), None)
    if not run:
        raise ValueError('The original task execution is missing; inspect its saved checkout before repair.')
    # A restart or lost response after session submission adopts that execution;
    # it must never send the same repair as another turn.
    if run.get('session_request_id') == request_id:
        repair.update(state='running', message='Agent is resolving conflicts in the existing PR branch.')
        return save(service, task, 'pr_repair_started')
    if any(reserves(j, task['profile_id']) for j in jobs):
        repair['message'] = 'Queued: another job still owns this agent session.'
        return save(service, task, 'pr_repair_waiting')
    other = service.active_execution(task['profile_id'], [j for j in jobs if j['id'] != run['id']])
    if other:
        if other.get('task_id'):
            with service.operation('task:' + other['task_id'], timeout=0):
                previous = service.get(other['task_id'])
                finished, reason = service.execution_finished(previous, other)
                if finished:
                    service.finish_execution(previous, other, request_id + '-previous', 'pr_repair_scheduler')
                else:
                    repair['message'] = 'Queued: the assigned agent is finishing other work. ' + reason
                    return save(service, task, 'pr_repair_waiting')
        else:
            repair['message'] = 'Queued: inspect or release the agent’s other session before repair.'
            return save(service, task, 'pr_repair_waiting')
    with service.operation('launch-capacity', timeout=0):
        jobs = service.store.snapshot(live_status=False).get('jobs', [])
        occupied = sum(j.get('kind') == 'launch' and bool(j.get('task_id')) and j.get('state') not in ('finished', 'released') for j in jobs)
        held = int(bool(run.get('task_id')) and run.get('state') not in ('finished', 'released'))
        budget = service.session_budget(task['organization_id'], jobs)
        policy = budget['policy']
        if (occupied - held >= MAX_ACTIVE_EXECUTIONS or
                policy['max_active_sessions'] and budget['active'] - held >= policy['max_active_sessions'] or
                policy['daily_session_cap'] and budget['started'] >= policy['daily_session_cap']):
            repair['message'] = 'Queued: waiting for the organization session budget.'
            return save(service, task, 'pr_repair_waiting')
        pull = refresh_pull(service, task)
        if pull['head']['sha'] != repair['head_sha'] or pull['base'].get('sha') != repair['upstream_sha']:
            raise ValueError('The PR head or upstream base changed while queued. Inspect and request a fresh repair.')
        if pull.get('mergeable') is not False:
            if pull.get('mergeable') is None:
                repair['message'] = 'Queued: GitHub is calculating mergeability.'
                return save(service, task, 'pr_repair_waiting')
            repair.update(state='obsolete', message='GitHub no longer reports conflicts; no agent prompt was sent.')
            return service.save(task, 'pr_repair_obsolete', 'pr_repair_scheduler')
        if run.get('state') == 'persona_sent':
            agent = service.store.identity(run, ready=False)
            if agent.get('agent_status', agent.get('state')) not in ('idle', 'done'):
                repair['message'] = 'Queued: the original agent is still working or needs your decision. Inspect its session.'
                return save(service, task, 'pr_repair_waiting')
        profile = next((p for p in service.store.snapshot(live_status=False)['profiles'] if p['id'] == task['profile_id']), None)
        if (not profile or profile.get('archived') or profile.get('ephemeral') or profile.get('group_id')
                or not profile.get('use_worktree', True) or Path(profile.get('project', '')).resolve() != service.path_for(task)):
            raise ValueError('The assigned persistent worktree profile changed; inspect it before repair.')
        if service.store.model_validator is not None:
            service.store.model_validator(profile)
        repository, path = service.path_for(task), service.tree_for(task)
        with repository_lock(repository):
            if (project_git.git(path, 'rev-parse', 'HEAD').strip() != repair['head_sha'] or
                    project_git.merge_state(path) or project_git.git(path, 'status', '--porcelain=v1', '--untracked-files=all').strip()):
                raise ValueError('Original PR checkout is changed or has unfinished work; inspect it before repair.')
            project_git.fetch(repository)
            project_git.git(path, 'cat-file', '-e', repair['upstream_sha'] + '^{commit}')
            if not repair.get('recovery'):
                repair['recovery'] = project_git.recovery_snapshot(service.projects,
                    path.relative_to(service.projects).as_posix(), hashlib.sha256(request_id.encode()).hexdigest())
            repair.update(state='starting', message='Preparing the saved task session for conflict repair.')
            service.save(task, 'pr_repair_prepared', 'pr_repair_scheduler')
        if run.get('state') == 'persona_sent':
            service.store.manage_session(dict(mode='finish', job_id=run['id'], organization_id=task['organization_id'],
                inspected=True, request_id=request_id + '-archive'), 'pr_repair_scheduler')
            archived = next((j for j in service.store.snapshot(live_status=False)['jobs']
                             if j['id'] == run['id']), None)
            if archived is None:
                raise ValueError('The original execution disappeared while archiving; inspect the agent session.')
            run = archived
        if run.get('state') not in ('finished', 'released') or not run.get('session_archive_id'):
            raise ValueError('The original session must have a verified archive before restarting its checkout.')
        with repository_lock(repository):
            if (project_git.git(path, 'rev-parse', 'HEAD').strip() != repair['head_sha'] or
                    project_git.merge_state(path) or project_git.git(path, 'status', '--porcelain=v1', '--untracked-files=all').strip()):
                raise ValueError('The original checkout changed during archival; inspect it before repair.')
        service.store.manage_session(dict(mode='handover', job_id=run['id'], organization_id=task['organization_id'],
            target_profile_id=task['profile_id'], archive_id=run['session_archive_id'], inspected=True,
            continuation_context='Continue the same task and PR in its preserved checkout. The explicit conflict-repair '
                                 'assignment replaces the old implementation prompt.', task_prompt=instructions(task),
            request_id=request_id), 'pr_repair_scheduler')
        repair.update(state='running', started_at=stamp(), message='Agent is resolving conflicts in the existing PR branch.')
        return service.save(task, 'pr_repair_started', 'pr_repair_scheduler')


def reconcile(service, task):
    from collaboration import current_run
    from contributions import stamp
    repair = task['pr_repair']
    if task['state'] in ('merged', 'closed', 'completed'):
        repair.update(state='obsolete' if repair['state'] == 'queued' else 'needs_attention',
                      message='The PR closed while repair was pending. Inspect any active agent session.')
        return save(service, task, 'pr_repair_needs_attention')
    if repair['state'] == 'needs_attention':
        run = next((j for j in service.store.snapshot(live_status=False)['jobs'] if j['id'] == task.get('run_id')), {})
        if (not repair.get('monitoring_retry')
                or run.get('session_request_id') != 'pr-repair-' + repair['id']
                or run.get('state') not in ('queued', 'running', 'persona_sent')):
            return  # Uncertain ownership must never trigger a new launch.
        # Compatibility for interrupted monitoring written by older versions.
        # Recovery is recorded only after a fresh identity read succeeds below.
    if repair['state'] in ('queued', 'preparing', 'starting'):
        return dispatch(service, task)
    if repair['state'] == 'validating':
        build = (task.get('builds') or {}).get(repair['candidate'], {})
        if build.get('target') != repair['candidate']:
            if not service.validation or service.validation.snapshot().get('executor') != 'service':
                repair['message'] = 'Waiting for the durable build service. Install it under Builds & deployments.'
                return save(service, task, 'pr_repair_waiting')
            return service.perform('build', {'target': repair['candidate']}, task['id'], 'pr_repair_scheduler')
        if build.get('state') == 'complete' and build.get('required_checks_verified') is True:
            repair.update(state='ready', message='Repaired candidate passed required checks. Review and publish to update the existing PR.')
            return service.save(task, 'pr_repair_validated', 'pr_repair_scheduler')
        if build.get('state') in ('failed', 'error', 'interrupted', 'complete'):
            repair.update(state='validation_failed', message='Repaired candidate validation needs attention. Inspect Checks & builds.')
            return service.save(task, 'pr_repair_validation_failed', 'pr_repair_scheduler')
        return
    run = next((j for j in service.store.snapshot(live_status=False)['jobs'] if j['id'] == task.get('run_id')), None)
    if not run or run.get('state') in ('needs_attention', 'released', 'finished'):
        raise ValueError(str((run or {}).get('error') or 'Repair session needs inspection.'))
    if run.get('state') in ('queued', 'running'):
        return
    try:
        agent = current_run(service.store, run, ready=False)
        # current_run returns the launch binding; the verified agent lives in identity.
        agent = service.store.identity(agent, ready=False)
    except (ValueError, OSError) as error:
        recoverable = isinstance(error, OSError) or (
            isinstance(error, HerdrError) and error.code in ('timeout', 'server_not_running', 'herdr_error'))
        if not recoverable:
            repair.pop('monitoring_retry', None)
            save(service, task, 'pr_repair_waiting')
            raise
        failures = int(repair.get('monitoring_failures') or 0) + 1
        repair.update(monitoring_retry=True, monitoring_failures=failures,
                      monitoring_failed_since=repair.get('monitoring_failed_since') or stamp(),
                      monitoring_error=str(error)[:500])
        if failures >= READ_FAILURE_LIMIT:
            repair['state'] = 'monitoring_unavailable'
        repair['message'] = (f'Session status unavailable ({failures} consecutive reads failed). '
                             'Read-only monitoring retries automatically; repair completion is not yet verified. '
                             + str(error)[:500])
        return save(service, task, 'pr_repair_monitoring_unavailable' if failures == READ_FAILURE_LIMIT
                    else 'pr_repair_monitoring_retry')
    recovered = repair.pop('monitoring_retry', None)
    for key in ('monitoring_failures', 'monitoring_failed_since', 'monitoring_error'):
        repair.pop(key, None)
    if recovered:
        repair.update(state='running', message='Session status recovered; monitoring the existing repair.')
        save(service, task, 'pr_repair_recovered')
    status = agent.get('agent_status', agent.get('state'))
    if status == 'blocked':
        repair.update(state='waiting_for_input', message='The agent needs your decision in its session. Monitoring continues.')
        return save(service, task, 'pr_repair_waiting_for_input')
    if status not in ('idle', 'done'):
        repair.update(state='running', message='Agent is resolving conflicts and running the task checks.')
        return save(service, task, 'pr_repair_progress')
    path = service.tree_for(task)
    with repository_lock(path):
        head = project_git.git(path, 'rev-parse', 'HEAD').strip()
        try:
            receipt = service.read_receipt(task, run, head, path)
        except (ValueError, OSError):
            repair['message'] = 'Awaiting the repair session’s completion receipt; idle alone is not completion.'
            return save(service, task, 'pr_repair_waiting')
        if receipt['outcome'] != 'complete':
            raise ValueError('The repair session reported ' + str(receipt['outcome']) + ' rather than a completed repair.')
        if head == repair['head_sha']:
            raise ValueError('Repair must produce a new committed candidate, not reuse the old completion receipt.')
        try:
            for sha in (repair['head_sha'], repair['upstream_sha']):
                project_git.git(path, 'merge-base', '--is-ancestor', sha, head)
        except ValueError:
            raise ValueError('The repaired candidate must preserve the published commit and incorporate the pinned upstream commit.') from None
        if project_git.merge_state(path) or project_git.git(path, 'status', '--porcelain=v1', '--untracked-files=all').strip():
            raise ValueError('Repair checkout is dirty or has unresolved Git operations.')
        task['base_sha'] = repair['upstream_sha']
        task['completion_receipt'] = dict(commit=head, tests=receipt['tests'], verified_at=stamp())
        service.save(task, 'pr_repair_receipt', 'pr_repair_scheduler')
        task = service.perform('candidate', {}, task['id'], 'pr_repair_scheduler')
    repair = task['pr_repair']
    repair.update(state='validating', candidate=head, message='Conflict resolution committed; validating the new candidate.')
    task['state'] = 'pr_open'
    return service.save(task, 'pr_repair_candidate', 'pr_repair_scheduler')


def advance(service, task_ids=None):
    from contributions import Busy
    ids = service.select_task_ids("json_extract(data, '$.pr_repair.state') IN "
                                 "('queued','preparing','starting','running','waiting_for_input','monitoring_unavailable','validating','needs_attention')", task_ids)
    for task_id in ids:
        try:
            with service.operation('task:' + task_id, timeout=0):
                task = service.get(task_id)
                reconcile(service, task)
        except Busy:
            continue
        except (ValueError, OSError) as error:
            try:
                with service.operation('task:' + task_id, timeout=0):
                    task = service.get(task_id)
                    task['pr_repair'].update(state='needs_attention', message=str(error)[:500])
                    save(service, task, 'pr_repair_needs_attention')
            except Busy:
                continue
