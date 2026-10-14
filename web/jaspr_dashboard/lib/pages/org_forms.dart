import 'org_form_values.dart';
import 'package:web/web.dart' as web;
import '../ui.dart';
import 'model_catalog.dart';
import 'org_ui.dart';

typedef Json = Map<String, dynamic>;
Component prose(Object? value) => el('p', [text(value)]);
Component pre(Object? value) =>
    el('pre', [text(value)], classes: 'terminal-output');
Component details(String title, List<Component> children) => el('details', [
  el('summary', [text(title)]),
  ...children,
]);
Component row(List<Component> children) =>
    el('div', children, classes: 'actions');
List<Json> records(dynamic values) => [
  for (final v in values as List? ?? [])
    if (v is Map) Map<String, dynamic>.from(v),
];
List<String> paths(String source) => parseAccessiblePaths(source);
String? validatePaths(String source) => validateAccessiblePaths(source);

Future<Json?> editRecord(
  String title,
  Json initial,
  Map<String, String> labels, {
  Set<String> required = const {},
  Set<String> long = const {},
  Map<String, Map<String, String>> choices = const {},
  Map<String, int> limits = const {},
  List<Component> Function(Json)? extra,
  String? Function(Json)? validate,
  Set<String> flags = const {},
  void Function(String key, dynamic value, Json values)? changed,
  bool Function(String key, Json values)? visible,
  Set<String> wide = const {},
}) {
  final values = Json.from(initial);
  String? error;
  // Short inputs and selects pair up two per row; text areas, switches,
  // [wide] keys (paths) and a short field without a partner take the full
  // width of the form. Pairs are recomputed from the visible fields.
  bool short(String key) =>
      !long.contains(key) && !flags.contains(key) && !wide.contains(key);
  Set<String> halves() {
    final shown = [
      for (final key in labels.keys)
        if (visible == null || visible(key, values)) key,
    ];
    final result = <String>{};
    for (var i = 0; i < shown.length - 1; i++) {
      if (short(shown[i]) &&
          short(shown[i + 1]) &&
          !result.contains(shown[i])) {
        result.addAll([shown[i], shown[i + 1]]);
        i++;
      }
    }
    return result;
  }

  Component item(Set<String> half, String key, Component child) => el(
    'div',
    [child],
    classes: [
      'org-form__item',
      if (half.contains(key)) 'org-form__item--half',
      if (flags.contains(key)) 'org-form__item--switch',
    ].join(' '),
  );
  return showDialog<Json>(title, (close) {
    final half = halves();
    return el(
      'form',
      [
        for (final entry in labels.entries)
          if (visible != null && !visible(entry.key, values))
            const Component.empty()
          else if (flags.contains(entry.key))
            item(
              half,
              entry.key,
              el('label', [
                el(
                  'input',
                  [],
                  classes: 'switch__input',
                  attributes: {
                    'type': 'checkbox',
                    'role': 'switch',
                    'checked': '${values[entry.key] == true}',
                  },
                  events: {
                    'change': (e) {
                      values[entry.key] =
                          (e.target as web.HTMLInputElement).checked;
                      refreshDialogs();
                    },
                  },
                ),
                el('span', [text(entry.value)], classes: 'switch__label'),
              ], classes: 'switch'),
            )
          else if (choices.containsKey(entry.key))
            item(
              half,
              entry.key,
              select(
                entry.value,
                '${values[entry.key] ?? ''}',
                choices[entry.key]!,
                (v) {
                  values[entry.key] = v;
                  changed?.call(entry.key, v, values);
                  refreshDialogs();
                },
              ),
            )
          else if (long.contains(entry.key))
            item(
              half,
              entry.key,
              textarea(entry.value, '${values[entry.key] ?? ''}', (v) {
                values[entry.key] = v;
                changed?.call(entry.key, v, values);
                if (entry.key == 'project') refreshDialogs();
              }),
            )
          else
            item(
              half,
              entry.key,
              field(
                entry.value,
                '${values[entry.key] ?? ''}',
                (v) {
                  values[entry.key] = v;
                  changed?.call(entry.key, v, values);
                  if (entry.key == 'project') refreshDialogs();
                },
                required: required.contains(entry.key),
              ),
            ),
        ...?extra?.call(values),
        if (error != null) errorLine(error),
        el('div', [
          button('Cancel', () => close(null)),
          button('Save', () {
            for (final key in required) {
              if ('${values[key] ?? ''}'.trim().isEmpty) {
                error = 'Enter ${labels[key] ?? key}.';
                refreshDialogs();
                return;
              }
            }
            for (final entry in limits.entries) {
              if ('${values[entry.key] ?? ''}'.length > entry.value) {
                error =
                    '${labels[entry.key]} must be at most ${entry.value} characters.';
                refreshDialogs();
                return;
              }
            }
            error = validate?.call(values);
            if (error != null) {
              refreshDialogs();
              return;
            }
            for (final key in labels.keys) {
              if (values[key] is String)
                values[key] = (values[key] as String).trim();
            }
            close(values);
          }, primary: true),
        ], classes: 'actions org-dialog-actions'),
      ],
      classes: 'org-form',
      events: {'submit': (event) => event.preventDefault()},
    );
  });
}

Future<Json?> organizationForm([Json? org]) =>
    editRecord(
      org == null ? 'Create organization' : 'Edit organization',
      {'id': org?['id'] ?? '', ...?org},
      {
        'name': 'Organization name',
        'purpose': 'Purpose',
        'instructions': 'Shared instructions',
      },
      required: {'name', 'purpose'},
      long: {'purpose', 'instructions'},
      limits: {'name': 120, 'purpose': 2000, 'instructions': 8000},
      wide: {'name'},
    ).then(
      (v) => v == null
          ? null
          : {
              'id': v['id'],
              'name': v['name'],
              'purpose': v['purpose'],
              'instructions': v['instructions'],
            },
    );

Future<Json?> hireForm(
  Json org,
  List<Json> profiles,
  ModelCatalog catalog, [
  Json? profile,
]) async {
  final result = await editRecord(
    profile == null ? 'Hire an agent' : 'Edit persona',
    {
      'id': '',
      'organization_id': org['id'],
      'runtime': '',
      'permission_mode': 'default',
      'use_worktree': true,
      'manager_id': '',
      'project': '/home/herdr/projects',
      ...?profile,
      'accessible_paths': (profile?['accessible_paths'] as List? ?? []).join(
        '\n',
      ),
    },
    {
      'name': 'Name',
      'role': 'Role',
      'runtime': 'Runtime',
      'manager_id': 'Reports to',
      'project': 'Existing project directory',
      'use_worktree': 'Use a Git worktree',
      'persona': 'Persona instructions',
      'permission_mode': 'Permissions',
      'accessible_paths': 'Additional accessible path globs',
    },
    required: {'name', 'role', 'runtime', 'project', 'persona'},
    long: {'persona', 'accessible_paths'},
    flags: {'use_worktree'},
    limits: {'name': 120, 'role': 120, 'project': 2000, 'persona': 8000},
    wide: {'project'},
    choices: {
      'runtime': {
        '': 'Choose runtime',
        'codex': 'Codex',
        'claude': 'Claude',
        'opencode': 'OpenCode',
        'agy': 'Antigravity',
      },
      'manager_id': {
        '': 'Organization owner',
        for (final p in profiles.where((p) => p['id'] != profile?['id']))
          '${p['id']}': '${p['name']}',
      },
      'permission_mode': {
        'default': 'CLI defaults',
        'dashboard_outputs': 'Allow dashboard outputs',
        'full_autonomy': 'Full autonomy',
      },
    },
    changed: (key, value, v) {
      if (key == 'runtime')
        updateHireRuntime(v, '$value', creating: profile == null);
    },
    visible: (key, v) =>
        !['permission_mode', 'accessible_paths'].contains(key) ||
        v['runtime'] == 'opencode',
    extra: (v) => [
      if (v['runtime'] != 'agy' && '${v['runtime'] ?? ''}'.isNotEmpty)
        ModelFields(
          runtime: '${v['runtime']}',
          project: '${v['project']}',
          catalog: catalog,
          values: v,
          onChanged: refreshDialogs,
        ),
      note(
        'Saved settings apply on next launch. Connect the same CLI account before launching. Permission changes require relaunch. Full autonomy allows all tools; dashboard outputs grants reply/artifact folder access. Additional path globs allow external-directory access; this is not a sandbox.',
      ),
    ],
    validate: (v) {
      if (v['runtime'] == 'opencode' &&
          '${v['model'] ?? ''}'.trim().isNotEmpty &&
          '${v['provider'] ?? ''}'.trim().isEmpty)
        return 'Choose a provider for this model.';
      return validatePaths('${v['accessible_paths']}');
    },
  );
  if (result == null) return null;
  return {
    for (final key in [
      'id',
      'organization_id',
      'name',
      'role',
      'runtime',
      'provider',
      'model',
      'reasoning',
      'permission_mode',
      'use_worktree',
      'manager_id',
      'project',
      'persona',
    ])
      key: result[key] is String
          ? (result[key] as String).trim()
          : result[key] ?? '',
    'accessible_paths': paths('${result['accessible_paths']}'),
  };
}

Future<Json?> groupForm(List<Json> profiles, [Json? group]) async {
  final members = List<String>.from(group?['members'] ?? []);
  final result = await editRecord(
    group == null ? 'Create discussion group' : 'Edit discussion group',
    {
      'read_only': true,
      'use_worktree': true,
      'notify_outcomes': true,
      'create_tasks': false,
      'review_scope': 'topic',
      'permission_mode': 'default',
      ...?group,
      'accessible_paths': (group?['accessible_paths'] as List? ?? []).join(
        '\n',
      ),
    },
    {
      'name': 'Group name',
      'description': 'Topic, desired outcome and constraints',
      'review_scope': 'Default discussion scope',
      'read_only': 'Read-only discussion',
      'use_worktree': 'Use a Git worktree',
      'notify_outcomes': 'Notify group when its task finishes',
      'create_tasks': 'Create and queue qualifying tasks automatically',
      'permission_mode': 'Facilitator permissions',
      'accessible_paths': 'Additional accessible path globs',
    },
    required: {'name', 'description'},
    long: {'description', 'accessible_paths'},
    flags: {'read_only', 'use_worktree', 'notify_outcomes', 'create_tasks'},
    limits: {'name': 120, 'description': 8000},
    choices: {
      'review_scope': {
        'topic': 'Group topic',
        'repository': 'Whole repository at configured HEAD',
      },
      'permission_mode': {
        'default': 'CLI defaults',
        'dashboard_outputs': 'Allow dashboard outputs',
        'full_autonomy': 'Full autonomy',
      },
    },
    extra: (v) => [
      el('fieldset', [
        el('legend', [
          text('Members'),
          el('span', [
            text('${members.length} selected'),
          ], classes: 'org-form__legend-meta'),
        ], classes: 'org-form__legend'),
        note(
          'Choose 2–6 agents. Repository scope requires the same configured project. Facilitator permissions and worktree settings apply on next launch; members retain their own settings. Read-only is a discussion rule, not a sandbox. Automatic tasks remain subject to organization limits.',
        ),
        el('div', [
          for (final p in profiles.where((p) => p['group_id'] == null))
            el('label', [
              el(
                'input',
                [],
                attributes: {
                  'type': 'checkbox',
                  'checked': '${members.contains(p['id'])}',
                },
                events: {
                  'change': (e) {
                    if ((e.target as web.HTMLInputElement).checked) {
                      members.add('${p['id']}');
                    } else {
                      members.remove(p['id']);
                    }
                    refreshDialogs();
                  },
                },
              ),
              agentTile(p['name'], role: p['role'], size: 'xs'),
              el('span', [
                el('span', [text('${p['name']}')], classes: 'org-select__name'),
                el('span', [text('${p['role']}')], classes: 'org-select__meta'),
              ], classes: 'org-select__text'),
            ], classes: 'org-select org-select--chip'),
        ], classes: 'org-form__members'),
      ], classes: 'org-form__fieldset'),
    ],
    validate: (v) {
      if (members.length < 2 || members.length > 6) return 'Choose 2–6 agents.';
      return validatePaths('${v['accessible_paths']}');
    },
  );
  if (result == null) return null;
  return {
    if (group != null) 'id': group['id'],
    for (final k in [
      'name',
      'description',
      'read_only',
      'use_worktree',
      'notify_outcomes',
      'create_tasks',
      'review_scope',
      'permission_mode',
    ])
      k: result[k],
    'accessible_paths': paths('${result['accessible_paths']}'),
    'members': members,
  };
}
