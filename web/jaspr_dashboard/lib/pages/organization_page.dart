import 'org_form_values.dart';
import 'dart:async';
import 'dart:convert';
import 'package:web/web.dart' as web;
import '../services.dart';
import '../ui.dart';
import '../navigation.dart';
import 'org_forms.dart';
import 'model_catalog.dart';
import 'org_chart.dart';
import 'collaboration_panel.dart';
import 'organization_automation.dart';

class OrganizationPage extends StatefulComponent {
  const OrganizationPage({super.key, this.initialView = 'chart'});
  final String initialView;
  @override
  State<OrganizationPage> createState() => _OrganizationPageState();
}

class _OrganizationPageState extends State<OrganizationPage> {
  DashboardBloc get connection => dashboardConnection;
  late OrganizationBloc bloc;
  final subscriptions = <StreamSubscription>[];
  Timer? timer;
  int generation = -1;
  late String view = component.initialView == 'collaboration'
      ? 'collaborate'
      : component.initialView;
  String? error;
  bool cleaningSessions = false, transferring = false;
  final sessionRequests = <String, String>{};
  ModelCatalog catalog = const ModelCatalog({});
  String? get selected => connection.selectedOrganization.value;
  set selected(String? value) => connection.selectedOrganization.value = value;
  void selectionChanged() {
    if (mounted) setState(() {});
  }

  void notificationRefresh() {
    if (connection.state.connected && bloc.pending == null)
      bloc.send(OrganizationCommand('refresh'));
  }

  @override
  void initState() {
    super.initState();
    bind();
    subscriptions.add(
      connection.stream.listen((_) {
        if (!mounted) return;
        if (generation != connection.generation ||
            !connection.state.connected) {
          bind();
          sessionRequests.clear();
          error = null;
          catalog = const ModelCatalog({});
        }
        setState(() {});
      }),
    );
    connection.selectedOrganization.addListener(selectionChanged);
    connection.notificationRevision.addListener(notificationRefresh);
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (connection.state.connected && bloc.pending == null)
        bloc.send(OrganizationCommand('refresh'));
    });
    loadCatalog();
  }

  StreamSubscription? orgSubscription;
  void bind() {
    orgSubscription?.cancel();
    if (generation >= 0) bloc.dispose();
    generation = connection.generation;
    bloc = OrganizationBloc(connection);
    orgSubscription = bloc.stream.listen((_) {
      if (mounted) {
        final valid = bloc.state.organizations.where(
          (o) => o['removed_at'] == null,
        );
        if (valid.isNotEmpty && !valid.any((o) => o['id'] == selected))
          selected = '${valid.first['id']}';
        setState(() {});
      }
    });
    bloc.send(OrganizationCommand('refresh'));
  }

  @override
  void dispose() {
    timer?.cancel();
    orgSubscription?.cancel();
    for (final s in subscriptions) s.cancel();
    connection.selectedOrganization.removeListener(selectionChanged);
    connection.notificationRevision.removeListener(notificationRefresh);
    bloc.dispose();
    super.dispose();
  }

  Future<void> loadCatalog() async {
    final epoch = connection.generation;
    try {
      final result = await connection.request('models');
      if (mounted && epoch == connection.generation)
        setState(
          () => catalog = ModelCatalog.fromJson(result is Json ? result : null),
        );
    } catch (_) {}
  }

  Future<void> submit(String action, Json body) async {
    if (!connection.state.connected || bloc.state.busy || bloc.pending != null)
      return;
    await bloc.send(OrganizationCommand(action, body));
  }

  Future<void> editOrganization([Json? org]) async {
    final epoch = connection.generation;
    final values = await organizationForm(org);
    if (values == null || !mounted || epoch != connection.generation) return;
    final previous = bloc.state.organizations.map((o) => o['id']).toSet();
    await submit('save', values);
    if (mounted && org == null && bloc.state.error == null) {
      final created = bloc.state.organizations
          .where((o) => !previous.contains(o['id']))
          .firstOrNull;
      if (created != null) selected = created['id'];
    }
  }

  Future<void> hire(Json org, [Json? profile]) async {
    final epoch = connection.generation;
    final values = await hireForm(
      org,
      bloc.state.profiles
          .where(
            (p) => p['organization_id'] == org['id'] && p['group_id'] == null,
          )
          .toList(),
      catalog,
      profile,
    );
    if (values != null && mounted && epoch == connection.generation) {
      await submit('hire', values);
      if (mounted) setState(() => view = 'team');
    }
  }

  Future<void> delegate(Json org) async {
    final epoch = connection.generation;
    final profiles = bloc.state.profiles
        .where(
          (p) =>
              p['organization_id'] == org['id'] &&
              p['group_id'] == null &&
              bloc.state.jobs.any(
                (j) =>
                    j['kind'] == 'launch' &&
                    j['profile_id'] == p['id'] &&
                    j['state'] == 'persona_sent',
              ),
        )
        .toList();
    final choices = {for (final p in profiles) '${p['id']}': '${p['name']}'};
    final v = await editRecord(
      'Delegate work',
      {'organization_id': org['id']},
      {
        'sender_id': 'From launched agent',
        'profile_id': 'To launched agent',
        'task': 'Task instructions',
      },
      required: {'sender_id', 'profile_id', 'task'},
      long: {'task'},
      limits: {'task': 8000},
      choices: {
        'sender_id': {'': 'Select agent', ...choices},
        'profile_id': {'': 'Select agent', ...choices},
      },
      validate: (v) => v['sender_id'] == v['profile_id']
          ? 'Choose a different recipient.'
          : null,
    );
    if (v != null && mounted && epoch == connection.generation)
      await submit('delegate', v);
  }

  Future<String?> reportForm(
    String title,
    String label, {
    int limit = 8000,
  }) async {
    final v = await editRecord(
      title,
      {},
      {'result': label},
      required: {'result'},
      long: {'result'},
      limits: {'result': limit},
    );
    return v?['result'];
  }

  Future<void> report(Json job) async {
    final epoch = connection.generation;
    final v = await reportForm(
      'Record completion report',
      'Operator completion report',
    );
    if (v != null && mounted && epoch == connection.generation)
      await submit('report', {
        'organization_id': job['organization_id'],
        'job_id': job['id'],
        'result': v,
      });
  }

  Future<void> resolveDelegation(Json job, String decision) async {
    final epoch = connection.generation;
    final reason = await reportForm(
      decision == 'complete'
          ? 'Accept inspected delegation completion'
          : 'Cancel inspected delegation',
      'Inspection evidence and reason (releases work reservation)',
      limit: 2000,
    );
    if (reason != null && mounted && epoch == connection.generation)
      await submit('resolve_delegation', {
        'organization_id': job['organization_id'],
        'job_id': job['id'],
        'decision': decision,
        'inspected': true,
        'reason': reason,
      });
  }

  Future<void> release(Json job) async {
    final epoch = connection.generation;
    if (await confirm(
          'Release run binding?',
          'Allows another launch. It leaves the terminal and process running. Archive and close an idle session to stop it and avoid duplicate work.',
        ) &&
        mounted &&
        epoch == connection.generation)
      await submit('release', {
        'organization_id': job['organization_id'],
        'job_id': job['id'],
      });
  }

  Future<void> manageSession(Json job, String mode) async {
    final epoch = connection.generation;
    final descriptions = {
      'restart':
          'Starts a fresh session in retained checkout using the current profile, waits for instructions and does not replay the task.',
      'continue':
          'Starts a fresh session with archived evidence and current profile. It waits for instructions and does not resume or replay the task.',
      'resume':
          'Restores the archived provider conversation binding in retained checkout. Restoration is not completed work; it waits for instructions.',
      'close':
          'Preserves available evidence before closing a verified idle session. If capture fails, its pane stays open.',
    };
    if (!await confirm(
      '$mode session?',
      '${job['profile']?['name'] ?? job['profile_id']}\nAlias: ${job['alias']}\nPane: ${job['pane_id']}\n${descriptions[mode]}',
      confirmLabel: 'I inspected the idle session',
    ))
      return;
    if (!mounted || epoch != connection.generation) return;
    final selection = 'session:${job['id']}:$mode';
    final request = sessionRequests.putIfAbsent(selection, requestId);
    try {
      await connection.request('organizations/session', {
        'organization_id': job['organization_id'],
        'job_id': job['id'],
        'mode': mode,
        'inspected': true,
        'request_id': request,
        if (job['archive_id'] != null) 'archive_id': job['archive_id'],
      });
      if (!mounted || epoch != connection.generation) return;
      sessionRequests.remove(selection);
      bloc.send(OrganizationCommand('refresh'));
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() => error = '$e');
    }
  }

  Future<void> cleanupSessions(List<Json> jobs) async {
    final epoch = connection.generation;
    final organizationId = selected;
    final obsolete = jobs
        .where(
          (j) =>
              j['kind'] == 'launch' &&
              j['state'] == 'released' &&
              j['session_closed_at'] == null,
        )
        .toList();
    final chosen = <String>{};
    final ok = await showDialog<bool>(
      'Review obsolete sessions',
      (close) => el('div', [
        prose(
          'Only selected released sessions are considered. Busy, blocked, changed or unidentified sessions are skipped. Repository files remain intact.',
        ),
        for (final j in obsolete)
          el('label', [
            el(
              'input',
              [],
              attributes: {
                'type': 'checkbox',
                if (chosen.contains(j['id'])) 'checked': '',
              },
              events: {
                'change': (e) {
                  if ((e.target as web.HTMLInputElement).checked) {
                    chosen.add('${j['id']}');
                  } else {
                    chosen.remove(j['id']);
                  }
                  refreshDialogs();
                },
              },
            ),
            text(
              '${j['profile']?['name'] ?? j['profile_id']} · ${j['alias']} · ${j['pane_id'] ?? 'Pane identity missing'} · ${j['created_at']}',
            ),
          ], classes: 'checkbox-field'),
        row([
          button('Cancel', () => close(false)),
          button(
            'Archive and close selected',
            () => close(true),
            disabled: chosen.isEmpty,
            primary: true,
          ),
        ]),
      ]),
    );
    if (ok != true ||
        !mounted ||
        epoch != connection.generation ||
        organizationId != selected)
      return;
    setState(() => cleaningSessions = true);
    try {
      final result = await OrganizationCommand('session', {
        'organization_id': organizationId,
        'mode': 'cleanup',
        'job_ids': chosen.toList(),
        'inspected': true,
      }).execute(connection);
      if (!mounted || epoch != connection.generation) return;
      await showDialog<void>(
        'Session cleanup results',
        (close) => el('div', [
          for (final r in records(result['results']))
            prose('${r['id']}: ${r['state']} ${r['reason'] ?? ''}'),
          button('Close', () => close(null)),
        ]),
      );
      if (mounted && epoch == connection.generation)
        bloc.send(OrganizationCommand('refresh'));
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => cleaningSessions = false);
    }
  }

  Future<void> showArchives() async {
    final epoch = connection.generation;
    final organizationId = selected;
    bool current() =>
        mounted && epoch == connection.generation && organizationId == selected;
    try {
      final response = await connection.request('organizations/session', {
        'mode': 'archives',
        'organization_id': organizationId,
      });
      if (!current()) return;
      final archives = records(response['archives']);
      final chosen = await showDialog<Json>(
        'Archived sessions',
        (close) => el('div', [
          if (archives.isEmpty)
            prose(
              'No archives yet. Archive and close a verified idle session first.',
            ),
          for (final a in archives)
            card('${a['identity']?['name'] ?? 'Historical agent'}', [
              prose(
                '${a['alias']} · Archived ${a['archived_at']} ${a['native_resume_available'] == true ? '· Native resume available' : ''}',
              ),
              if (a['terminal_unavailable'] != null)
                prose('Terminal history unavailable; saved records only.'),
              button('View history', () => close(a)),
            ]),
          button('Close', () => close(null)),
        ]),
      );
      if (chosen == null || !current()) return;
      final data = await connection.request('organizations/session', {
        'mode': 'view_archive',
        'organization_id': organizationId,
        'archive_id': chosen['id'],
      });
      if (!current()) return;
      final native = data['native_resume_available'] == true;
      final action = await showDialog<String>(
        'Archived conversation: ${data['identity']?['name'] ?? 'agent'}',
        (close) => el('div', [
          prose(
            native
                ? 'Bounded historical evidence, not a complete provider transcript. Native resume restores the original conversation binding and waits for instructions.'
                : 'Bounded historical evidence, not a complete provider transcript. Continuing creates a fresh conversation and waits for instructions.',
          ),
          pre(
            'Checkout: ${data['worktree_path'] ?? data['source_project']}\nBranch: ${data['worktree_branch']}\nTask: ${data['task_id']}',
          ),
          if (data['terminal_capture']?['forced_stop'] == true)
            prose(
              'Forced stop: visible screen only, up to 160 lines. Earlier history is omitted; reply may be incomplete.',
            ),
          if (data['terminal_capture']?['character_truncated'] == true)
            prose('Terminal output exceeded archive character limit.'),
          pre(
            data['terminal'] ??
                data['terminal_unavailable'] ??
                'Terminal unavailable.',
          ),
          for (final m in data['messages'] as List? ?? []) pre(m),
          row([
            button(
              'Download archive',
              () =>
                  downloadText(jsonEncode(data), 'session-${data['id']}.json'),
            ),
            button('Close', () => close(null)),
            if (native)
              button('Resume original conversation', () => close('resume')),
            button(
              'Continue with saved context',
              () => close('continue'),
              primary: true,
            ),
          ]),
        ]),
      );
      if (action != null && current())
        await manageSession({
          'id': data['run_id'],
          'organization_id': organizationId,
          'archive_id': data['id'],
          'alias': data['alias'],
          'pane_id': data['pane_id'],
          'profile': data['identity'],
        }, action);
    } catch (e) {
      if (current()) setState(() => error = '$e');
    }
  }

  Future<void> transfer(bool importing) async {
    if (transferring) return;
    final epoch = connection.generation;
    setState(() {
      transferring = true;
      error = null;
    });
    try {
      if (!importing) {
        final data = await connection.request('organizations/export');
        if (!mounted || epoch != connection.generation) return;
        await downloadText(
          const JsonEncoder.withIndent('  ').convert(data),
          'herdr-configuration.json',
        );
        toast(
          data['import_size_supported'] == false
              ? 'Complete backup downloaded, but it exceeds the 2 MB import limit. Increase migration capacity before replacing the LXC.'
              : 'Configuration downloaded. Keep this file before replacing the LXC.',
        );
      } else {
        final content = await pickConfiguration();
        if (content == null || !mounted || epoch != connection.generation)
          return;
        final data = jsonDecode(content) as Json;
        final importSummary = configurationImportSummary(data);
        if (!await confirm(
          'Import configuration?',
          '$importSummary Existing records will not be overwritten. Paths and permission settings are preserved; review them before launching. No agents start automatically.',
          confirmLabel: 'Import',
        ))
          return;
        if (!mounted || epoch != connection.generation) return;
        await connection.request('organizations/import', data);
        if (!mounted || epoch != connection.generation) return;
        await bloc.send(OrganizationCommand('refresh'));
        toast(
          'Configuration imported. Review paths and connect CLI accounts before launching.',
        );
      }
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() => error = 'Configuration transfer failed: $e');
    } finally {
      if (mounted) setState(() => transferring = false);
    }
  }

  Component run(Json job, bool busy) {
    final admin = connection.operator.value['role'] == 'admin';
    return card(
      '${job['kind'] == 'launch' ? 'Launch' : 'Delegation'} · ${bloc.state.profiles.where((p) => p['id'] == job['profile_id']).firstOrNull?['name'] ?? 'Agent'}',
      [
        badge('${job['state']}'),
        prose('Updated: ${job['updated_at']}'),
        if (job['profile'] is Map)
          prose(
            'Model at launch: ${savedModelLabel(Map<String, dynamic>.from(job['profile']))} · Reasoning: ${savedReasoningLabel(Map<String, dynamic>.from(job['profile']))}',
          ),
        if (job['launch_arguments'] is List)
          pre(
            'Arguments sent to Herdr: ${(job['launch_arguments'] as List).join(' ')}',
          ),
        if (job['alias'] != null)
          pre(
            'Herdr name: ${job['alias']} · Pane: ${job['pane_id'] ?? 'not allocated'}',
          ),
        if (job['task'] != null)
          pre('From ${job['sender_name']}: ${job['task']}'),
        if (job['workspace_mode'] == 'worktree')
          pre(
            'Worktree: ${job['worktree_path']}\nBranch: ${job['worktree_branch']}',
          ),
        if (job['workspace_note'] != null) prose(job['workspace_note']),
        if (job['error'] != null) prose(job['error']),
        if (job['resolution'] is Map)
          prose(
            'Resolved: ${job['resolution']['decision']} · ${job['resolution']['reason']}',
          ),
        if (job['result'] != null)
          pre('Operator completion report: ${job['result']}'),
        if (job['kind'] == 'delegate' &&
            admin &&
            [
              'delivered',
              'reported_complete',
              'needs_attention',
              'uncertain',
            ].contains(job['state']))
          row([
            if (job['state'] == 'reported_complete')
              button(
                'Accept completion and free agent',
                () => resolveDelegation(job, 'complete'),
                disabled: busy,
              ),
            button(
              'Cancel after inspection',
              () => resolveDelegation(job, 'cancel'),
              disabled: busy,
            ),
          ]),
        if (job['kind'] == 'launch' &&
            ['persona_sent', 'released'].contains(job['state']) &&
            job['session_closed_at'] == null &&
            admin)
          row([
            button(
              'Archive and close session',
              () => manageSession(job, 'close'),
              disabled: busy,
            ),
            if (job['state'] == 'persona_sent')
              button(
                'Restart in assigned checkout',
                () => manageSession(job, 'restart'),
                disabled: busy,
              ),
          ]),
        if (job['kind'] == 'launch' &&
            !['queued', 'running', 'released'].contains(job['state']))
          button('Release run binding', () => release(job), disabled: busy),
        if (job['kind'] == 'delegate' && job['state'] == 'delivered')
          button('Record completion report', () => report(job), disabled: busy),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final state = bloc.state;
    final organizations = state.organizations
        .where((o) => o['removed_at'] == null)
        .toList();
    final org =
        organizations.where((o) => o['id'] == selected).firstOrNull ??
        organizations.firstOrNull;
    final busy = state.busy || bloc.pending != null;
    final profiles = state.profiles
        .where(
          (p) =>
              p['organization_id'] == org?['id'] &&
              p['group_id'] == null &&
              p['removed_at'] == null,
        )
        .toList();
    final jobs = state.jobs
        .where((j) => j['organization_id'] == org?['id'])
        .toList();
    return el('div', [
      card('Organization', [
        select('Organization', '${org?['id'] ?? ''}', {
          '': 'Select organization',
          for (final o in organizations) '${o['id']}': '${o['name']}',
        }, (v) => selected = v.isEmpty ? null : v),
        row([
          button(
            'Create organization',
            () => editOrganization(),
            disabled: busy,
          ),
          if (org != null)
            button(
              'Edit organization',
              () => editOrganization(org),
              disabled: busy,
            ),
          button(
            'Refresh',
            () => bloc.send(OrganizationCommand('refresh')),
            disabled: state.busy,
          ),
        ]),
        if (state.error != null) notice(state.error, error: true),
        if (error != null) notice(error, error: true),
        if (bloc.pending != null)
          row([
            button(
              'Retry same request',
              () => bloc.send(bloc.pending!),
              disabled: state.busy,
            ),
            button(
              'Dismiss request',
              () => setState(() => bloc.pending = null),
              disabled: state.busy,
            ),
          ]),
        if (org != null) ...[
          prose(org['purpose']),
          details('Shared instructions', [pre(org['instructions'])]),
          row([
            for (final item in {
              'chart': 'Org chart',
              'team': 'Team',
              'collaborate': 'Chat & groups',
              'runs': 'Runs',
              'automation': 'Automation',
            }.entries)
              button(
                item.value,
                () => setState(() => view = item.key),
                primary: view == item.key,
              ),
          ]),
          row([
            button(
              'Hire an agent',
              () => hire(org),
              disabled: busy,
              primary: true,
            ),
            button(
              'Delegate work',
              () => delegate(org),
              disabled: busy || profiles.length < 2,
            ),
          ]),
        ],
      ]),
      if (org != null && view == 'chart')
        OrgChart(
          profiles: profiles,
          agents: connection.state.agents,
          jobs: jobs,
          groups: state.groups
              .where(
                (g) =>
                    g['organization_id'] == org['id'] &&
                    g['removed_at'] == null,
              )
              .toList(),
          onSelect: (p) => navigate('/agents/${p['id']}'),
          onSelectGroup: (g) => navigate('/groups/${g['id']}'),
          onConfigure: (p) => hire(org, p),
        ),
      if (org != null && view == 'team')
        el('div', [
          for (final p in profiles)
            card('${p['name']}', [
              prose('${p['role']} · ${p['runtime']}'),
              if (p['coordination_binding'] != null)
                prose(
                  p['coordination_binding'] == 'used'
                      ? 'Used by coordination: ${(p['coordination_repositories'] as List? ?? []).join(', ')}'
                      : 'Inactive coordinator profile · no repository binding',
                ),
              prose(
                'Model: ${savedModelLabel(p)} · Reasoning: ${savedReasoningLabel(p)}',
              ),
              details('Persona and responsibilities', [
                pre(p['persona']),
                prose('Project: ${p['project']}'),
                prose(
                  'Reports to: ${profiles.where((x) => x['id'] == p['manager_id']).firstOrNull?['name'] ?? 'Organization owner'}',
                ),
                prose('Persona v${p['version']}'),
              ]),
              row([
                button('Open console', () => navigate('/agents/${p['id']}')),
                button('Edit persona', () => hire(org, p), disabled: busy),
                button('Remove agent', () async {
                  final epoch = connection.generation;
                  if (await confirm(
                        'Remove ${p['name']}?',
                        'Removes this agent and closes its bound Herdr terminal. History, artifacts and worktree files are preserved. Remove it from groups first.',
                      ) &&
                      mounted &&
                      epoch == connection.generation)
                    await submit('remove_agent', {
                      'organization_id': org['id'],
                      'profile_id': p['id'],
                    });
                }, disabled: busy),
                button(
                  'Launch ${p['name']}',
                  () => submit('launch', {
                    'organization_id': org['id'],
                    'profile_id': p['id'],
                  }),
                  disabled:
                      busy ||
                      jobs.any(
                        (j) =>
                            j['kind'] == 'launch' &&
                            j['profile_id'] == p['id'] &&
                            j['state'] != 'released',
                      ),
                  primary: true,
                ),
              ]),
            ]),
        ], classes: 'cards-grid'),
      if (org != null && view == 'collaborate')
        CollaborationPanel(
          key: ValueKey('collaboration-${org['id']}'),
          organization: org,
          profiles: profiles,
          onOpenGroup: (id) => navigate('/groups/$id'),
        ),
      if (org != null && view == 'runs') ...[
        if (connection.operator.value['role'] == 'admin')
          row([
            button(
              'Clean up obsolete panes',
              () => cleanupSessions(jobs),
              disabled: busy || cleaningSessions,
            ),
            button('Archived sessions', showArchives, disabled: busy),
          ]),
        prose(
          'Delivery confirms terminal input, not completed work. Launch states are historical; see Live agents for current activity.',
        ),
        for (final job in jobs.reversed.where(
          (j) => ['launch', 'delegate'].contains(j['kind']),
        ))
          run(job, busy),
      ],
      if (org != null && view == 'automation')
        OrganizationAutomation(
          key: ValueKey('policy-${org['id']}'),
          organizationId: '${org['id']}',
        ),
      details('Migration & backup', [
        prose(
          'Exports all organizations, archived entries, models, personas, permissions, project paths, worktree preferences, reporting lines and groups. Runtime sessions, discussions, repositories, recovery snapshots and credentials need separate backups.',
        ),
        row([
          button(
            'Export configuration',
            () => transfer(false),
            disabled: transferring,
          ),
          button(
            'Import configuration',
            () => transfer(true),
            disabled: transferring,
          ),
        ]),
      ]),
    ]);
  }
}
