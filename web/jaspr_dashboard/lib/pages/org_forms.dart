import 'org_form_values.dart';
import 'dart:convert';
import 'dart:math';
import 'package:herdr_dashboard_state/team_template_draft.dart';
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
                      changed?.call(entry.key, values[entry.key], values);
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

Future<Json?> organizationForm([
  Json? org,
  Json? templates,
  Future<Json> Function(Json)? preview,
  Future<Json> Function(Json)? library,
  bool canManageTemplates = true,
  Map<String, String> projectFolders = const {},
  String? projectFolderError,
]) async {
  final roles = org == null ? records(templates?['roles']) : <Json>[];
  final draft = TeamTemplateDraft(
    roles,
    maxMembers: templates?['max_members'] as int? ?? 20,
  );
  final bundles = records(templates?['bundles']);
  final savedTemplates = records(templates?['saved_templates']);
  final savedChoices = <String, String>{'': 'Custom draft'};
  void updateSavedChoices() {
    savedChoices
      ..clear()
      ..[''] = 'Custom draft';
    for (final entry in savedTemplates) {
      for (final version in records(entry['versions'])) {
        savedChoices['${entry['id']}@${version['version']}'] =
            '${version['name'] ?? entry['name']} · v${version['version']}';
      }
    }
  }

  updateSavedChoices();
  Json? sourceTemplate, libraryPending;
  List<dynamic>? loadedPreferences;
  List<dynamic> preferredValues(Json v) =>
      loadedPreferences ??
      [if (v['preferred_runtime'] != '') v['preferred_runtime']];
  bool libraryBusy = false;
  String? libraryError, libraryNotice;
  final resourceDefaults = Json.from(
    templates?['resource_defaults'] ??
        {
          'max_active_sessions': 4,
          'max_active_meetings': 1,
          'daily_session_cap': 20,
        },
  );
  const resourceLabels = {
    'max_active_sessions': 'Maximum concurrent sessions',
    'max_active_meetings': 'Maximum concurrent meetings',
    'daily_session_cap': 'Sessions per 24 hours',
  };
  Json resources(Json values) => {
    for (final key in resourceLabels.keys)
      key: int.tryParse('${values[key]}') ?? -1,
  };
  Json? team;
  Json? lastPreview;
  String? previewError;
  var revision = 0;
  var loading = false;
  void invalidate() {
    revision++;
    team = null;
    previewError = null;
    loading = false;
    libraryPending = null;
    refreshDialogs();
  }

  List<String> selected(Json v) => [
    for (final role in roles)
      if (v['preset_${role['id']}'] == true) '${role['id']}',
  ];
  final result = await editRecord(
    org == null ? 'Create organization' : 'Edit organization',
    {
      'id': org?['id'] ?? '',
      ...?org,
      'model_policy': 'balanced',
      'preferred_runtime': '',
      'team_preset': '',
      'saved_template': '',
      'template_name': '',
      'template_description': '',
      ...resourceDefaults,
      'project': '',
    },
    {
      'name': 'Organization name',
      'purpose': 'Purpose',
      'instructions': 'Shared instructions',
      if (roles.isNotEmpty) ...{
        if (library != null) 'saved_template': 'Saved template version',
        if (bundles.isNotEmpty) 'team_preset': 'Team preset',
        for (final role in roles) 'preset_${role['id']}': '${role['name']}',
        'project': 'Team project directory',
        'model_policy': 'Model policy',
        'preferred_runtime': 'Preferred CLI',
        ...resourceLabels,
      },
    },
    required: {'name', 'purpose'},
    long: {'purpose', 'instructions'},
    limits: {
      'name': 120,
      'purpose': 2000,
      'instructions': 8000,
      'project': 2000,
    },
    wide: {'name', 'project'},
    flags: {for (final role in roles) 'preset_${role['id']}'},
    choices: {
      'project': {'': 'Select a project folder', ...projectFolders},
      'saved_template': savedChoices,
      'model_policy': Map<String, String>.from(templates?['policies'] ?? {}),
      'preferred_runtime': {
        '': 'Automatic',
        ...Map<String, String>.from(templates?['runtime_names'] ?? {}),
      },
      'team_preset': {
        '': 'Custom team',
        for (final bundle in bundles) '${bundle['id']}': '${bundle['name']}',
      },
    },
    visible: (key, v) =>
        !{
          'project',
          'model_policy',
          'preferred_runtime',
          ...resourceLabels.keys,
        }.contains(key) ||
        selected(v).isNotEmpty,
    changed: (key, value, v) {
      if (key == 'saved_template') {
        sourceTemplate = null;
        invalidate();
        if ('$value'.isNotEmpty && library != null) {
          final epoch = revision;
          libraryBusy = true;
          libraryError = null;
          refreshDialogs();
          final parts = '$value'.split('@');
          () async {
            try {
              final record = await library({
                'action': 'read',
                'template_id': parts[0],
                'version': int.parse(parts[1]),
              });
              if (epoch != revision) return;
              sourceTemplate = record;
              final definition = Json.from(record['definition']);
              draft.hydrate(definition['team_members']);
              for (final role in roles)
                v['preset_${role['id']}'] = draft.selectedRoles.contains(
                  role['id'],
                );
              v['model_policy'] = definition['model_policy'];
              loadedPreferences = List.from(
                definition['runtime_preferences'] as List? ?? [],
              );
              v['preferred_runtime'] =
                  (definition['runtime_preferences'] as List? ?? [])
                      .firstOrNull ??
                  '';
              v['team_preset'] = '';
              v['template_name'] = record['name'];
              v['template_description'] = record['description'];
              for (final key in resourceLabels.keys)
                v[key] = definition['resource_limits'][key];
              lastPreview = null;
              invalidate();
              libraryNotice =
                  'Loaded ${record['name']} · v${record['version']}. Re-preview for this project and its CLI accounts.';
            } catch (e) {
              libraryError = '$e';
            } finally {
              libraryBusy = false;
              refreshDialogs();
            }
          }();
        }
      }
      if (key == 'team_preset') {
        sourceTemplate = null;
        v['saved_template'] = '';
        final bundle = bundles.where((b) => b['id'] == value).firstOrNull;
        if (bundle != null) {
          draft.applyBundle(bundle);
          for (final role in roles)
            v['preset_${role['id']}'] = draft.selectedRoles.contains(
              role['id'],
            );
          v['model_policy'] = bundle['model_policy'];
          for (final key in resourceLabels.keys)
            v[key] =
                (bundle['resource_limits'] as Map?)?[key] ??
                resourceDefaults[key];
        }
        invalidate();
      }
      if (key.startsWith('preset_') ||
          key == 'project' ||
          key == 'model_policy' ||
          key == 'preferred_runtime' ||
          resourceLabels.containsKey(key)) {
        if (key == 'preferred_runtime') loadedPreferences = null;
        final withinLimit =
            !key.startsWith('preset_') || draft.syncRoles(selected(v));
        invalidate();
        if (!withinLimit) {
          for (final role in roles)
            v['preset_${role['id']}'] = draft.selectedRoles.contains(
              role['id'],
            );
          previewError = 'A team supports up to ${draft.maxMembers} members.';
        }
      }
    },
    validate: (v) {
      if (libraryBusy) return 'Wait for the template operation to finish.';
      if (selected(v).isEmpty) return null;
      if (!projectFolders.containsKey(v['project']))
        return 'Select the team project directory.';
      if (team == null || loading)
        return 'Preview the selected team before saving.';
      return null;
    },
    extra: (v) => [
      if (libraryBusy) prose('Loading or saving template…'),
      if (libraryError != null) errorLine(libraryError),
      if (libraryNotice != null) prose(libraryNotice),
      if (org == null && templates?['error'] != null)
        errorLine('${templates!['error']}'),
      if (roles.isNotEmpty)
        prose(
          'Select roles to create with this organization. Profiles are ready for tasks; sessions start when launched.',
        ),
      for (final bundle in bundles.where((b) => b['id'] == v['team_preset']))
        prose(bundle['description']),
      if (selected(v).isNotEmpty) ...[
        if (projectFolderError != null)
          errorLine(projectFolderError)
        else if (projectFolders.isEmpty)
          prose(
            'No project folders are available. Add or clone a project in the project explorer, then reopen this form.',
          ),
        prose(
          'Resource limits cover every launched session, including idle sessions and review helpers. Use 0 for unlimited.',
        ),
        button(
          loading ? 'Checking CLI accounts…' : 'Preview team',
          () async {
            final epoch = ++revision;
            loading = true;
            team = null;
            previewError = null;
            refreshDialogs();
            try {
              final result = await preview!({
                ...draft.payload,
                'project': '${v['project'] ?? ''}'.trim(),
                'model_policy': v['model_policy'],
                'runtime_preferences': preferredValues(v),
                'team_preset': v['team_preset'],
                'resource_limits': resources(v),
                if (sourceTemplate != null) ...{
                  'template_id': sourceTemplate!['id'],
                  'template_version': sourceTemplate!['version'],
                },
              });
              if (epoch == revision) {
                team = result;
                lastPreview = result;
                draft.hydrate(result['member_specs']);
              }
            } catch (e) {
              if (epoch == revision) previewError = '$e';
            } finally {
              if (epoch == revision) loading = false;
              refreshDialogs();
            }
          },
          disabled:
              loading ||
              libraryBusy ||
              preview == null ||
              !projectFolders.containsKey(v['project']),
        ),
        for (final member in draft.members) ...[
          details('Configure ${draft.name(member)}', [
            field('Member name', draft.name(member), (value) {
              member['name'] = value;
              invalidate();
            }),
            textarea(
              'Persona responsibilities',
              '${member['persona'] ?? draft.role('${member['template_role']}')['persona_instruction'] ?? ''}',
              (value) {
                member['persona'] = value;
                invalidate();
              },
            ),
            select(
              'Member CLI',
              '${member['runtime'] ?? ''}',
              {
                '': 'Automatic',
                ...Map<String, String>.from(templates?['runtime_names'] ?? {}),
              },
              (value) {
                if (value.isEmpty)
                  member.remove('runtime');
                else
                  member['runtime'] = value;
                for (final key in [
                  'provider',
                  'model',
                  'reasoning',
                  'permission_mode',
                  'accessible_paths',
                ])
                  member.remove(key);
                invalidate();
              },
            ),
            ...memberModelFields(member, lastPreview, invalidate),
            select(
              'Reports to',
              '${member['manager_key'] ?? '__auto__'}',
              {
                '__auto__': 'Role default',
                '': 'Organization owner',
                for (final manager in draft.members)
                  if (manager['key'] != member['key'])
                    '${manager['key']}': draft.name(manager),
              },
              (value) {
                if (value == '__auto__')
                  member.remove('manager_key');
                else
                  member['manager_key'] = value;
                invalidate();
              },
            ),
            row([
              button(
                'Add another ${draft.role('${member['template_role']}')['name']}',
                () {
                  draft.add('${member['template_role']}', member);
                  invalidate();
                },
                disabled: draft.members.length >= draft.maxMembers,
              ),
              button('Remove ${draft.name(member)}', () {
                final roleId = member['template_role'];
                draft.remove('${member['key']}');
                v['preset_$roleId'] = draft.selectedRoles.contains(roleId);
                invalidate();
              }),
            ]),
          ]),
        ],
        if (previewError != null) errorLine(previewError),
        if (lastPreview != null)
          details('CLI account check from last preview', [
            for (final account in records(lastPreview?['accounts']))
              prose(
                '${account['name']}: ${account['available'] == true ? 'Available' : 'Excluded'} · ${account['reason']}',
              ),
          ]),
        if (library != null && canManageTemplates)
          details('Save reusable template', [
            prose(
              'Save this team configuration without its project path or CLI account data. New versions do not update existing organizations.',
            ),
            field('Template name', '${v['template_name']}', (value) {
              v['template_name'] = value;
              libraryPending = null;
            }),
            textarea('Template description', '${v['template_description']}', (
              value,
            ) {
              v['template_description'] = value;
              libraryPending = null;
            }),
            row([
              for (final update in [false, if (sourceTemplate != null) true])
                button(
                  update ? 'Save new version' : 'Save as new template',
                  () async {
                    if (libraryBusy) return;
                    libraryBusy = true;
                    libraryError = null;
                    libraryNotice = null;
                    final intent = {
                      'action': 'save',
                      'name': '${v['template_name']}'.trim(),
                      'description': '${v['template_description']}'.trim(),
                      'definition': {
                        ...draft.payload,
                        'model_policy': v['model_policy'],
                        'runtime_preferences': preferredValues(v),
                        'resource_limits': resources(v),
                      },
                      if (update) ...{
                        'template_id': sourceTemplate!['id'],
                        'expected_version': sourceTemplate!['version'],
                      },
                    };
                    final previous = libraryPending == null
                        ? null
                        : (Json.from(libraryPending!)..remove('request_id'));
                    if (jsonEncode(previous) != jsonEncode(intent)) {
                      libraryPending = {
                        ...intent,
                        'request_id':
                            '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0x7fffffff)}',
                      };
                    }
                    refreshDialogs();
                    final saveEpoch = revision;
                    try {
                      final saved = await library(libraryPending!);
                      final header = savedTemplates
                          .where((t) => t['id'] == saved['id'])
                          .firstOrNull;
                      final versions = records(
                        header?['versions'],
                      ).where((t) => t['version'] != saved['version']).toList();
                      final metadata = {
                        'id': saved['id'],
                        'name': saved['name'],
                        'description': saved['description'],
                        'version': saved['version'],
                        'versions': [
                          {'version': saved['version'], 'name': saved['name']},
                          ...versions,
                        ],
                      };
                      savedTemplates.removeWhere((t) => t['id'] == saved['id']);
                      savedTemplates.add(metadata);
                      updateSavedChoices();
                      if (saveEpoch == revision) {
                        sourceTemplate = saved;
                        draft.hydrate(saved['definition']['team_members']);
                        v['saved_template'] =
                            '${saved['id']}@${saved['version']}';
                        invalidate();
                      }
                      libraryNotice =
                          'Saved ${saved['name']} · v${saved['version']}. Re-preview before creating the organization.';
                    } catch (e) {
                      libraryError = '$e';
                    } finally {
                      libraryBusy = false;
                      refreshDialogs();
                    }
                  },
                  disabled: libraryBusy,
                ),
            ]),
          ]),
        for (final warning in team?['warnings'] as List? ?? []) prose(warning),
        for (final member in records(team?['members']))
          details(
            '${member['name']} · ${member['runtime']} · ${member['model_name']}',
            [
              prose(
                'Reports to: ${member['manager_name'] ?? (member['manager_role'] == '' ? 'Organization owner' : 'Lead Developer')} · Reasoning: ${member['reasoning'] == '' ? 'Model default' : member['reasoning']}',
              ),
              prose(member['selection_note']),
              prose('Separate worktree · CLI default permissions'),
              pre(member['persona']),
            ],
          ),
      ],
    ],
  );
  if (result == null) return null;
  return {
    for (final key in ['id', 'name', 'purpose', 'instructions'])
      key: result[key],
    if (org == null && selected(result).isNotEmpty) ...{
      ...draft.payload,
      'project': result['project'],
      'model_policy': result['model_policy'],
      'runtime_preferences': preferredValues(result),
      'template_plan': team!['template_plan'],
      'team_preset': result['team_preset'],
      'resource_limits': resources(result),
      if (sourceTemplate != null) ...{
        'template_id': sourceTemplate!['id'],
        'template_version': sourceTemplate!['version'],
      },
    },
  };
}

List<Component> memberModelFields(
  Json member,
  Json? preview,
  void Function() changed,
) {
  final resolved = records(
    preview?['members'],
  ).where((m) => m['template_key'] == member['key']).firstOrNull;
  final runtime = '${member['runtime'] ?? resolved?['runtime'] ?? ''}';
  final runtimes = preview?['runtimes'] as Map? ?? {};
  final entry = runtimes[runtime] as Map? ?? {};
  final models = records(entry['models']);
  if (runtime.isEmpty || runtime == 'agy' || models.isEmpty) return [];
  final model = models
      .where(
        (m) =>
            m['id'] == (member['model'] ?? resolved?['model']) &&
            m['provider'] == (member['provider'] ?? resolved?['provider']),
      )
      .firstOrNull;
  final reasoning = (model?['reasoning'] as List? ?? [])
      .map((v) => '$v')
      .toList();
  return [
    select(
      'Member model',
      member['model'] == null
          ? ''
          : jsonEncode([member['provider'] ?? '', member['model']]),
      {
        '': 'Automatic for role',
        for (final model in models)
          jsonEncode(
            [model['provider'] ?? '', model['id']],
          ): '${model['provider'] == '' ? '' : '${model['provider']}/'}${model['name']}',
      },
      (value) {
        member.remove('reasoning');
        if (value.isEmpty) {
          member.remove('provider');
          member.remove('model');
        } else {
          final pair = jsonDecode(value) as List;
          member['runtime'] = runtime;
          member['provider'] = pair[0];
          member['model'] = pair[1];
        }
        changed();
      },
    ),
    if (runtime != 'opencode' || entry['supports_variants'] == true)
      select(
        'Member reasoning',
        '${member['reasoning'] ?? '__auto__'}',
        {
          '__auto__': 'Automatic for role',
          '': 'Model default',
          for (final value in reasoning) value: value,
        },
        (value) {
          if (value == '__auto__')
            member.remove('reasoning');
          else
            member['reasoning'] = value;
          changed();
        },
      ),
  ];
}

Future<Json?> hireForm(
  Json org,
  List<Json> profiles,
  ModelCatalog catalog, [
  Json? profile,
  List<Json> runtimes = const [],
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
      'runtime': runtimeChoices(runtimes, profile),
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
