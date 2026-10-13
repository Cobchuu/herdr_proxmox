"""Explicit, audited realignment of stale sessions before discussion submission."""
from contextlib import closing
from pathlib import Path
import threading


def mismatches(store, job, records=None):
    if job.get('discussion_scope') != 'repository' or job.get('discussion_submitted_at'):
        return []
    # Callers that already hold the launch records pass them: the history page
    # renders every discussion, and rebuilding the organization's launches per
    # discussion would grow with both counts.
    if records is None:
        records = store.job_records(launches_only=True)
    profiles = {}
    with closing(store.connect()) as db:
        for identity in [*(job.get('group') or {}).get('members', []),
                         (job.get('group_run') or {}).get('profile_id')]:
            if not identity or identity in profiles:
                continue
            try:
                profiles[identity] = store.get(db, 'profiles', identity, job['organization_id'])
            except ValueError:
                # A removed member must not fail the whole history page; the
                # facilitator lookup below already tolerates a missing profile.
                continue
    facilitator = profiles.get((job.get('group_run') or {}).get('profile_id'), {})
    expected = facilitator.get('project')
    result = []
    for profile_id, profile in profiles.items():
        run = next((r for r in reversed(records) if r.get('profile_id') == profile_id
                    and r['state'] not in ('released', 'finished')), None)
        if not run:
            continue
        saved = (run.get('profile') or {}).get('project')
        current = profile.get('project')
        if not saved or not current or not expected:
            continue
        if Path(saved).resolve() == Path(current).resolve() == Path(expected).resolve():
            continue
        result.append(dict(run_id=run['id'], profile_id=profile_id, name=profile['name'],
                           alias=run.get('alias'),
                           session_project=saved, configured_project=current, expected_project=expected,
                           repairable=Path(current).resolve() == Path(expected).resolve()
                           and Path(saved).resolve() != Path(current).resolve() and run['state'] == 'persona_sent'
                           and not run.get('task_id')))
    shown = {item['run_id'] for item in result}
    for run_id, record in (job.get('session_realignments') or {}).items():
        if record.get('new_run_id') or run_id in shown:
            continue
        old = next((run for run in records if run['id'] == run_id), None)
        target = record.get('target') or {}
        profile = profiles.get(target.get('profile_id'), {})
        if old and old.get('session_closed_at') and profile.get('project') == target.get('configured_project'):
            result.append(dict(target, repairable=True, recovery_pending=True,
                               recovery_error=record.get('error', 'Relaunch was interrupted after archiving.')))
    return result


def realign(store, body, actor):
    from organizations import text, now
    if body.get('inspected') is not True or type(body.get('force', False)) is not bool:
        raise ValueError('Inspect the session and explicitly choose normal or forced realignment.')
    org = text(body, 'organization_id', 40)
    job_id = text(body, 'job_id', 40)
    run_id = text(body, 'run_id', 40)
    with store.lock:
        lock = store.agent_locks.setdefault('discussion-realignment:' + job_id, threading.RLock())
    if not lock.acquire(blocking=False):
        raise ValueError('Session realignment is already in progress.')
    try:
        with closing(store.connect()) as db:
            job = store.get(db, 'jobs', job_id, org)
            run = store.get(db, 'jobs', run_id, org)
        if (job['kind'] != 'discussion' or job.get('discussion_submitted_at')
                or job['state'] not in ('needs_attention', 'uncertain')):
            raise ValueError('Only an unsubmitted discussion needing attention can realign sessions.')
        record = (job.get('session_realignments') or {}).get(run_id)
        if record and record.get('new_run_id'):
            return dict(id=job_id, new_run_id=record['new_run_id'], status='already_realigned')
        targets = mismatches(store, job)
        target = next((item for item in targets if item['run_id'] == run_id and item['repairable']), None)
        # Resume after an archive/close succeeded but the new launch was interrupted.
        if not target and record and run.get('session_closed_at'):
            target = record['target']
        if (not target or target['configured_project'] != body.get('expected_project')
                or run.get('alias') != body.get('expected_alias')):
            raise ValueError('Session or project selection changed; refresh the group before realigning.')
        with closing(store.connect()) as db:
            profile = store.get(db, 'profiles', run['profile_id'], org)
        if profile.get('project') != target['configured_project']:
            raise ValueError('Configured project changed; refresh the group before realigning.')
        if store.contributions:
            owner = store.contributions.session_owner(run_id, [j for j in store.job_records() if j['id'] != job_id])
            if owner:
                raise ValueError('Another job owns this session; resolve that work before realigning, even with force.')
        records = job.get('session_realignments') or {}
        records[run_id] = dict(record or {}, target=target, actor=actor, force=body.get('force', False),
                              requested_at=now(), state='requested')
        store.update_job(job_id, session_realignments=records)
        try:
            store.manage_session(dict(organization_id=org, job_id=run_id, mode='close', inspected=True),
                                 actor, allow_busy=body.get('force', False))
            with closing(store.connect()) as db:
                latest = store.get(db, 'profiles', run['profile_id'], org)
            if latest.get('project') != target['configured_project']:
                raise ValueError('Configured project changed during closure; refresh before relaunching.')
            # A fresh launch uses the current profile; restart deliberately retains the old checkout.
            launched = store.action('launch', dict(organization_id=org, profile_id=run['profile_id'],
                request_id='realign-' + job_id + '-' + run_id))
            records[run_id].update(state='launched', new_run_id=launched['id'], error='')
            store.update_job(job_id, session_realignments=records)
        except (ValueError, OSError) as error:
            records[run_id].update(state='failed', error=str(error)[:1000])
            store.update_job(job_id, session_realignments=records)
            raise
        return dict(id=job_id, new_run_id=launched['id'], status='launched')
    finally:
        lock.release()
