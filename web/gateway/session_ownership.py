"""Which jobs still reserve their participant sessions.

These are active admission reservations, not all unresolved ownership states.
Delivered delegations and ambiguous delivery may still own a bound session;
Contributions.session_owner also checks those recorded references before rotation.
A discussion waiting for input can resume and must retain its participants.
"""

# waiting_for_members has not acquired participants and must not prevent the
# work that already owns them from finishing.
ACTIVE_JOB_STATES = ('queued', 'running', 'waiting_for_input', 'waiting_environment')


def active(job):
    """True while this job still owns the sessions it reserved."""
    return isinstance(job, dict) and job.get('state') in ACTIVE_JOB_STATES


def reserves(job, profile_id=None):
    """True while `job` reserves its participants.

    With a profile id, only when that profile is one of them. This mirrors the
    `participants` fallback used across the gateway: a job with no explicit
    participant list reserves the profile it was created for.
    """
    if not active(job):
        return False
    if profile_id is None:
        return True
    # `participants` may be present and null, so `or` rather than a `.get`
    # default: a null list must fall back, not raise on `in None`.
    return profile_id in (job.get('participants') or [job.get('profile_id')])
