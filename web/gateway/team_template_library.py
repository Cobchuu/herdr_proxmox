"""Portable, immutable versions of customized organization team templates."""
from datetime import datetime, timezone
import hashlib
import json
import re
import uuid

import model_catalog
import team_templates
import template_resources
from permissions import accessible_paths, permission_mode

ID = re.compile(r'[a-f0-9]{32}')
MAX_TEMPLATES, MAX_VERSIONS = 50, 25


def schema(db):
    db.executescript('''
        CREATE TABLE IF NOT EXISTS team_templates (id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS team_template_versions (
            template_id TEXT NOT NULL, version INTEGER NOT NULL, data TEXT NOT NULL,
            PRIMARY KEY(template_id, version));
    ''')


def definition(values):
    from organizations import model_settings
    allowed = {'team_members', 'template_roles', 'model_policy', 'runtime_preferences', 'resource_limits', 'team_preset'}
    if not isinstance(values, dict) or set(values) - allowed:
        raise ValueError('Reusable templates contain team settings only; project paths and account data are not supported.')
    values = team_templates.expand(values)
    roles, policy = team_templates.validate(values)
    if not roles:
        raise ValueError('Select at least one template member.')
    specs = team_templates.member_specs(dict(values, template_roles=roles))
    available = {'runtimes': {r: model_catalog.curated(r) for r in ('codex', 'claude')}}
    available['runtimes']['agy'] = {'models': [dict(provider='', id='', name='CLI default', reasoning=[])]}
    available['runtimes']['opencode'] = {'models': [dict(provider='opencode', id='coder', name='Coding model', reasoning=['medium', 'high'], tool_call=True, context=64000)], 'supports_variants': True}
    # Offline validation checks syntax, graph and permission consistency. Exact
    # model/account/variant availability is checked again on every team preview.
    for spec in specs:
        runtime = spec.get('runtime', '')
        if not isinstance(runtime, str) or runtime and runtime not in available['runtimes']:
            raise ValueError('Choose a supported member CLI.')
        if not runtime and any(spec.get(k) for k in ('model', 'provider')):
            raise ValueError('Choose a CLI for explicit model settings.')
        normalized = model_settings(spec, runtime or 'codex')
        for key, value in normalized.items():
            if key in spec:
                spec[key] = value
        if runtime:
            settings = model_settings(spec, runtime)
            permission_mode(spec, runtime)
            accessible_paths(spec, runtime)
            if settings['model']:
                entry = available['runtimes'][runtime]
                entry['models'] = [m for m in entry['models'] if (m['id'], m.get('provider', '')) != (settings['model'], settings['provider'])]
                entry['models'].append(dict(id=settings['model'], provider=settings['provider'], name=settings['model'],
                                           reasoning=[settings['reasoning']] if settings['reasoning'] else [], tool_call=True, context=64000))
    graph_specs = [{k: v for k, v in spec.items() if k not in ('provider', 'model', 'reasoning')} for spec in specs]
    plan = team_templates.plan(dict(values, team_members=graph_specs), available)
    frozen = []
    for spec, member in zip(specs, plan['members']):
        frozen.append(dict(spec, name=member['name'], persona=member['persona_instruction'],
                           manager_key=member['manager_key'], use_worktree=member['use_worktree']))
    return dict(team_members=frozen, model_policy=policy, runtime_preferences=team_templates.preferences(values),
                resource_limits=template_resources.validate(values.get('resource_limits')))


def digest(record):
    return hashlib.sha256(json.dumps([record['name'], record['description'], record['definition']], sort_keys=True).encode()).hexdigest()


def catalog(db):
    result = []
    for row in db.execute('SELECT data FROM team_templates ORDER BY rowid'):
        item = json.loads(row[0])
        item['versions'] = [dict(version=r[0], name=json.loads(r[1])['name']) for r in db.execute(
            'SELECT version,data FROM team_template_versions WHERE template_id=? ORDER BY version DESC', (item['id'],))]
        result.append(item)
    return result


def read(db, identifier, version=None):
    if not isinstance(identifier, str) or not ID.fullmatch(identifier):
        raise ValueError('Select a valid saved team template.')
    header = db.execute('SELECT data FROM team_templates WHERE id=?', (identifier,)).fetchone()
    if not header:
        raise ValueError('Saved team template not found.')
    latest = json.loads(header[0])['version']
    version = latest if version is None else version
    if type(version) is not int or not 1 <= version <= MAX_VERSIONS:
        raise ValueError('Select a valid template version.')
    row = db.execute('SELECT data FROM team_template_versions WHERE template_id=? AND version=?', (identifier, version)).fetchone()
    if not row:
        raise ValueError('Saved team template version not found.')
    return dict(json.loads(row[0]), latest_version=latest)


def save(db, body, actor):
    from organizations import text
    name, description = text(body, 'name'), text(body, 'description', 2000, optional=True)
    content = definition(body.get('definition'))
    identifier = body.get('template_id', '')
    if not isinstance(identifier, str):
        raise ValueError('Select a valid saved team template.')
    if identifier:
        previous = read(db, identifier)
        if type(body.get('expected_version')) is not int or body['expected_version'] != previous['version']:
            raise ValueError('This template has a newer version. Load the latest version before saving your changes, or save as a new template.')
        version = previous['version'] + 1
        if version > MAX_VERSIONS:
            raise ValueError('Template version limit reached; save as a new template.')
    else:
        if db.execute('SELECT count(*) FROM team_templates').fetchone()[0] >= MAX_TEMPLATES:
            raise ValueError('Saved template limit reached.')
        identifier, version = uuid.uuid4().hex, 1
    for row in db.execute('SELECT data FROM team_templates WHERE id!=?', (identifier,)):
        if json.loads(row[0])['name'].casefold() == name.casefold():
            raise ValueError('A template with this name already exists. Choose a different name.')
    record = dict(id=identifier, version=version, name=name, description=description, definition=content,
                  saved_at=datetime.now(timezone.utc).isoformat(), saved_by=actor, schema_version=1)
    record['digest'] = digest(record)
    db.execute('INSERT INTO team_template_versions VALUES (?,?,?)', (identifier, version, json.dumps(record)))
    header = {k: record[k] for k in ('id', 'version', 'name', 'description')}
    db.execute('INSERT INTO team_templates VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', (identifier, json.dumps(header)))
    from notifications import record as notify
    notify(db, 'policy', 'template-' + identifier, '')
    return dict(record, latest_version=version)


def export(db):
    return dict(team_templates=[json.loads(r[0]) for r in db.execute('SELECT data FROM team_templates')],
                team_template_versions=[json.loads(r[0]) for r in db.execute('SELECT data FROM team_template_versions ORDER BY template_id,version')])


def validate_import(bundle):
    headers, versions = bundle.get('team_templates', []), bundle.get('team_template_versions', [])
    if not isinstance(headers, list) or not isinstance(versions, list) or len(headers) > MAX_TEMPLATES or len(versions) > MAX_TEMPLATES * MAX_VERSIONS:
        raise ValueError('Invalid saved template backup.')
    mapped, seen = {}, set()
    for item in headers:
        if (not isinstance(item, dict) or set(item) != {'id', 'version', 'name', 'description'} or
                not isinstance(item.get('id'), str) or not ID.fullmatch(item['id']) or item['id'] in mapped):
            raise ValueError('Invalid saved template identity.')
        if type(item.get('version')) is not int or not 1 <= item['version'] <= MAX_VERSIONS:
            raise ValueError('Invalid saved template version.')
        mapped[item['id']] = item
    for item in versions:
        if (not isinstance(item, dict) or set(item) != {'id', 'version', 'name', 'description', 'definition', 'saved_at', 'saved_by', 'schema_version', 'digest'} or
                not isinstance(item.get('id'), str) or item['id'] not in mapped or type(item.get('version')) is not int):
            raise ValueError('Saved template version has no header.')
        key = (item['id'], item['version'])
        if (key in seen or not 1 <= item['version'] <= mapped[item['id']]['version'] or
                type(item.get('schema_version')) is not int or item['schema_version'] != 1):
            raise ValueError('Invalid or duplicate saved template version.')
        seen.add(key)
        if (not isinstance(item.get('name'), str) or not item['name'].strip() or len(item['name']) > 120 or '\x00' in item['name'] or
                not isinstance(item.get('description'), str) or len(item['description']) > 2000 or '\x00' in item['description']):
            raise ValueError('Invalid saved template name or description.')
        if any(not isinstance(item.get(k), str) or len(item[k]) > 160 or '\x00' in item[k] for k in ('saved_by', 'saved_at')):
            raise ValueError('Invalid saved template audit metadata.')
        if definition(item.get('definition')) != item['definition'] or digest(item) != item.get('digest'):
            raise ValueError('Saved template definition or digest is invalid.')
    for identifier, header in mapped.items():
        if any((identifier, n) not in seen for n in range(1, header['version'] + 1)):
            raise ValueError('Saved template history is incomplete.')
        latest = next(v for v in versions if v['id'] == identifier and v['version'] == header['version'])
        if header != {k: latest[k] for k in ('id', 'version', 'name', 'description')}:
            raise ValueError('Saved template header does not match its latest version.')
    return headers, versions


def import_records(db, records):
    headers, versions = records
    existing_ids = {r[0] for r in db.execute('SELECT id FROM team_templates')}
    if len(existing_ids | {item['id'] for item in headers}) > MAX_TEMPLATES:
        raise ValueError('Saved template limit reached.')
    for item in versions:
        row = db.execute('SELECT data FROM team_template_versions WHERE template_id=? AND version=?', (item['id'], item['version'])).fetchone()
        if row and json.loads(row[0]) != item:
            raise ValueError('Saved template version already exists with different content.')
    for item in headers:
        row = db.execute('SELECT data FROM team_templates WHERE id=?', (item['id'],)).fetchone()
        if row and json.loads(row[0]) != item:
            raise ValueError('Saved template header already exists with different content.')
    for item in headers:
        db.execute('INSERT OR IGNORE INTO team_templates VALUES (?,?)', (item['id'], json.dumps(item)))
    for item in versions:
        db.execute('INSERT OR IGNORE INTO team_template_versions VALUES (?,?,?)', (item['id'], item['version'], json.dumps(item)))
