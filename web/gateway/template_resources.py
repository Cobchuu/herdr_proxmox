"""Initial organization resource limits, independent of task automation."""
DEFAULTS = dict(max_active_sessions=4, max_active_meetings=1, daily_session_cap=20)
RANGES = dict(max_active_sessions=50, max_active_meetings=10, daily_session_cap=500)


def validate(values=None):
    if values is None:
        return dict(DEFAULTS)
    if not isinstance(values, dict) or set(values) - set(RANGES):
        raise ValueError('Choose supported organization resource limits.')
    result = dict(DEFAULTS)
    for key, value in values.items():
        if type(value) is not int or not 0 <= value <= RANGES[key]:
            raise ValueError(f'Invalid {key}: use an integer from 0 to {RANGES[key]} (0 means unlimited).')
        result[key] = value
    return result


def saved(store, organization_id):
    from template_workflows import organizations
    org = next((o for o in organizations(store) if o.get('id') == organization_id and not o.get('removed_at')), {})
    values = org.get('resource_limits')
    if values is None:
        return {}
    try:
        return validate(values)
    except ValueError:
        return {}  # Malformed imported metadata never grants new limits.
