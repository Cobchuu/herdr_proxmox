"""Durable pre-launch admission, separate from SDK acquisition and terminal input.

Only the existing organization launch job may resume. Waiting is safe to recover;
once a launch reaches the external runtime, its existing uncertain-delivery rule
still requires reconciliation instead of replaying a task prompt.
"""
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
import json
import logging
import sqlite3
import threading
import uuid

import environment_plan
import environment_recipes
import environment_execution
from environment_policy import EnvironmentPolicies
import project_git
from repository_lock import common_directory
import toolchain_policy


class AdmissionStopped(ValueError):
    def __init__(self, message, state='superseded'):
        super().__init__(message)
        self.state = state


def permission(policy):
    return {key: policy.get(key, False if key != 'auto_prepare_revision' else '')
            for key in ('auto_prepare', 'auto_prepare_checks', 'auto_prepare_agent', 'auto_prepare_restore', 'auto_prepare_revision')}


class EnvironmentAdmission:
    def __init__(self, organizations, preparation):
        self.organizations = organizations
        self.preparation = preparation
        self.store = preparation.store
        self.policies = EnvironmentPolicies(organizations.projects, self.store)
        self.owner = uuid.uuid4().hex
        self.scheduled = set()
        from environment_assistance import EnvironmentAssistance
        self.assistance = EnvironmentAssistance(self)

    def policy(self, organization):
        contributions = self.organizations.contributions
        return permission(contributions.policy(organization)) if contributions is not None else permission({})

    def job(self, identity):
        with self.organizations.lock, closing(self.organizations.connect()) as db:
            return self.organizations.get(db, 'jobs', identity)

    def update(self, identity, states, **fields):
        with self.organizations.lock, closing(self.organizations.connect()) as db, db:
            job = self.organizations.get(db, 'jobs', identity)
            if job['state'] not in states:
                return None
            job.update(fields)
            self.organizations.put(db, 'jobs', job)
            return job

    def admit(self, job):
        if job['kind'] != 'launch':
            return True
        approved = self.policy(job['organization_id'])
        existing = job.get('environment_admission') or {}
        if existing.get('state') == 'ready':
            try:
                waiter = self.store.waiter(job['id'])
                if not waiter or existing.get('waiter_id') != waiter['id']:
                    raise AdmissionStopped('The environment continuation identity is unavailable.')
                if self.current(waiter) is None:
                    return False
            except (ValueError, OSError) as error:
                self.update(job['id'], ('queued',), state='needs_attention',
                            error=str(error)[:1000])
                return False
            return True
        if approved['auto_prepare'] is not True:
            return True
        try:
            selected = Path(self.organizations.project(job['profile']['project']))
            if not any((parent / '.git').exists() for parent in (selected, *selected.parents)
                       if parent.is_relative_to(self.organizations.projects)):
                return True  # Existing non-repository conversations remain available.
            origin = common_directory(selected).parent
            project = origin.relative_to(self.organizations.projects).as_posix()
            base = job.get('start_sha') or project_git.configured_base(origin) or 'HEAD'
            revision = project_git.git(origin, 'rev-parse', '--verify', base + '^{commit}').strip()
            intent = dict(version=1, action='task_launch', project=project, revision=revision,
                          organization_id=job['organization_id'], profile_id=job['profile_id'], policy=approved)
            intent['preparation_key'] = environment_plan.digest({key: value for key, value in intent.items()
                                                               if key != 'profile_id'})
            parked = self.update(job['id'], ('queued',), state='waiting_environment', start_sha=revision,
                                 environment_intent=intent, launch_stage='preparing_environment',
                                 error='', progress='Preparing the recorded project environment before launch')
            if parked:
                self.store.wait(job['id'], intent)
                self.preparation.wake.set()
            return False
        except (ValueError, OSError) as error:
            self.update(job['id'], ('queued', 'waiting_environment'), state='needs_attention', error=str(error)[:1000])
            return False

    def current(self, waiter, starting=False):
        job = self.job(waiter['identity'])
        if job.get('environment_intent') != waiter['intent']:
            raise AdmissionStopped('The launch environment intent was superseded.')
        if self.policy(job['organization_id']) != waiter['intent']['policy']:
            raise AdmissionStopped('Environment preparation permission changed while this launch waited.')
        if job.get('start_sha') != waiter['intent']['revision']:
            raise AdmissionStopped('The launch starting revision changed while preparation was pending.')
        if job['state'] not in (('waiting_environment', 'queued', 'running') if starting else ('waiting_environment', 'queued')):
            raise AdmissionStopped('The launch is no longer waiting; no continuation was submitted.',
                                   'cancelled' if job['state'] in ('released', 'cancelled', 'finished') else 'superseded')
        with self.organizations.lock, closing(self.organizations.connect()) as db:
            profile = self.organizations.get(db, 'profiles', job['profile_id'], job['organization_id'])
        if profile.get('version') != job['profile'].get('version'):
            raise AdmissionStopped('The agent configuration changed while environment preparation was pending.')
        if job.get('task_id'):
            task = self.organizations.contributions.get(job['task_id'])
            if (task.get('state') in ('completed', 'cancelled', 'closed', 'merged')
                    or task.get('profile_id') != job['profile_id']
                    or task.get('base_sha') != waiter['intent']['revision']
                    or task.get('run_id') and task['run_id'] != job['id']):
                raise AdmissionStopped('The task was completed, cancelled, reassigned or superseded before environment readiness.')
            if not task.get('run_id'):
                if (datetime.now(timezone.utc) - datetime.fromisoformat(waiter['created_at'])).total_seconds() > 30:
                    raise AdmissionStopped('The task did not record this launch; inspect the interrupted admission.')
                return None  # The task transaction has not yet recorded the accepted launch.
        return job

    def fail(self, waiter, error):
        message = str(error)[:1000]
        if not self.store.settle_waiter(waiter['id'], self.owner, getattr(error, 'state', 'failed'), error=message):
            return  # An expired worker must not close a new owner's session.
        assistance = self.store.assistance(waiter['id'])
        if assistance and assistance['state'] not in ('ready', 'adopting'):
            try:
                self.assistance.close(assistance)
            except (ValueError, OSError):
                pass  # An ambiguous binding must be inspected, never closed by guess.
            try:
                self.assistance.helper(assistance, state='needs_attention', error=message)
            except ValueError:
                pass  # Allocation may have failed before reserving a helper.
        self.update(waiter['identity'], ('waiting_environment',), state='needs_attention', error=message,
                    progress='Environment preparation stopped before runtime launch')

    def plan(self, waiter):
        job = self.current(waiter)
        if job is None:
            self.store.settle_waiter(waiter['id'], self.owner, 'pending')
            return
        intent = waiter['intent']
        reusable = self.store.reusable(waiter['intent']['preparation_key'])
        if reusable:
            plan = self.store.get(reusable['plan_digest'])
        else:
            source = self.organizations.projects / intent['project']
            policy = self.policies.resolve(source, revision=intent['revision'])
            if not policy.get('plan_digest') or not policy['toolchains'] and not policy['blockers']:
                # Explicit legacy self-build compatibility, or no SDK requirements.
                self.authorize(waiter, None)
                return
            unknown = [reason for reason in policy.get('blockers', []) if reason.startswith('Unresolved project capability:')]
            if unknown:
                raise ValueError('; '.join(unknown))
            assistance = self.store.assistance(waiter['id'])
            plan = self.store.get(assistance['plan_digest']) if assistance else self.preparation.plan(intent['project'], intent['revision'])
            if not assistance and intent['policy'].get('auto_prepare_agent'):
                plan = self.preparation.assisted_plan(plan)
            plan['verification_scope'] = 'isolated_commit'
            plan['automatic_policy'] = intent['policy']
            if environment_execution.requires_restore(plan) and not intent['policy'].get('auto_prepare_restore'):
                raise ValueError('Dependency restoration needs separate organization project-code permission.')
            if intent['policy']['auto_prepare_checks']:
                identifiers = environment_recipes.automatic(plan)
                plan['selected_checks'] = environment_recipes.select(plan, identifiers, 'organization_environment_policy')
            plan['digest'] = environment_plan.digest(plan)
            self.store.save(plan)
            if any(item.get('activation') != 'available' and item.get('preparation_method') != 'agent' for item in plan['requirements']):
                raise ValueError('Some requirements have no permitted preparation/activation adapter; resolve the plan blockers first.')
            if any(item.get('preparation_method') == 'agent' and item.get('activation') != 'available' for item in plan['requirements']):
                prepared = self.assistance.advance(waiter, job, plan)
                if prepared is None:
                    self.store.settle_waiter(waiter['id'], self.owner, 'pending')
                    return
                plan = prepared
        self.current(waiter)  # Permission/cancellation can change during metadata resolution.
        if self.preparation.stop.is_set():
            self.store.settle_waiter(waiter['id'], self.owner, 'pending')
            return
        self.store.enqueue(plan['digest'], waiter=waiter['id'], owner=self.owner)

    def authorize(self, waiter, frozen):
        job = self.current(waiter)
        if job is None:
            self.store.settle_waiter(waiter['id'], self.owner, 'waiting' if waiter.get('preparation_id') else 'pending')
            return
        if job['state'] == 'queued':
            self.store.settle_waiter(waiter['id'], self.owner, 'resumed')
            self.schedule(job['id'])
            return
        fields = dict(state='queued', launch_stage='environment_ready', error='', progress='',
                      environment_admission=dict(state='ready', waiter_id=waiter['id'],
                          intent_digest=waiter['intent_digest'], plan_digest=waiter.get('plan_digest'),
                          preparation_id=waiter.get('preparation_id'), generation=waiter.get('generation')))
        if frozen is not None:
            fields['toolchain_policy'] = frozen
        if self.update(job['id'], ('waiting_environment',), **fields):
            # If the process dies here, queued/environment_ready is safe to
            # recover. _execute claims it before any external runtime side effect.
            self.store.settle_waiter(waiter['id'], self.owner, 'resumed')
            self.schedule(job['id'])

    def resume(self, waiter):
        self.current(waiter)
        receipt = self.store.job(waiter['preparation_id'])
        if not receipt or receipt['generation'] != waiter['generation'] or receipt['state'] != 'ready':
            raise ValueError('The recorded preparation failed or was cancelled; no agent was launched. ' +
                             str((receipt or {}).get('error') or ''))
        intent = waiter['intent']
        source = self.organizations.projects / intent['project']
        policy = self.policies.resolve(source, revision=intent['revision'],
                                       plan_digest=waiter['plan_digest'], receipt_id=receipt['id'])
        if any(not entry['executables'] for entry in policy['toolchains']):
            raise ValueError('The prepared receipt does not bind every required component.')
        frozen = dict(policy=policy, digest=toolchain_policy.digest(policy),
                      plan_digest=waiter['plan_digest'], checkout=str(source))
        self.authorize(waiter, frozen)

    def schedule(self, identity):
        with self.organizations.lock:
            if identity in self.scheduled or self.preparation.stop.is_set():
                return
            self.scheduled.add(identity)
            future = self.organizations.worker.submit(self.organizations.execute, identity)
            self.organizations.futures.add(future)
            def done(completed):
                with self.organizations.lock:
                    self.scheduled.discard(identity)
                self.organizations._finished(completed)
            future.add_done_callback(done)

    def tick(self):
        # Recover the cross-store handoff before claiming work. No network or CLI
        # calls occur under the organization transaction or preparation claim.
        with self.organizations.lock, closing(self.organizations.connect()) as db:
            jobs = [json.loads(row['data']) for row in db.execute(
                "SELECT data FROM jobs WHERE json_extract(data,'$.state')='waiting_environment' OR "
                "(json_extract(data,'$.state')='queued' AND json_extract(data,'$.launch_stage')='environment_ready') LIMIT 100")]
        for job in jobs:
            if job['state'] == 'waiting_environment':
                self.store.wait(job['id'], job['environment_intent'])
            else:
                self.schedule(job['id'])
        for planning in (False, True):
            waiter = self.store.claim_waiter(self.owner, planning=planning)
            if waiter is None:
                continue
            finished = threading.Event()
            def renew(waiter_id=waiter['id'], event=finished):
                while not event.wait(20):
                    try:
                        if not self.store.renew_waiter(waiter_id, self.owner):
                            return
                    except (OSError, sqlite3.Error):
                        logging.exception('Environment continuation lease renewal failed.')
                        return
            heartbeat = threading.Thread(target=renew, daemon=True)
            heartbeat.start()
            try:
                self.plan(waiter) if planning else self.resume(waiter)
            except (ValueError, OSError) as error:
                if self.preparation.stop.is_set():
                    self.store.settle_waiter(waiter['id'], self.owner, 'pending' if planning else 'waiting')
                else:
                    self.fail(waiter, error)
            finally:
                finished.set()
                heartbeat.join(timeout=1)
