import 'snapshot_terminal.dart';
import 'dart:async';

import 'dart:convert';

import '../services.dart';

import '../navigation.dart';

import '../ui.dart';

import 'org_forms.dart';

import 'organization_automation.dart';

/// Job states that keep a group conversation live. Shared so the poll interval

/// and the live-streaming guard cannot drift apart.

const _activeJobStates = [
  'queued',

  'running',

  'waiting_for_members',

  'needs_attention',

  'waiting_for_input',
];

class GroupPage extends StatefulComponent {
  const GroupPage({super.key, required this.id});

  final String id;

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  DashboardBloc get connection => dashboardConnection;

  Map<String, dynamic>? group;

  List<Map<String, dynamic>> profiles = [];

  List<Map<String, dynamic>> jobs = [];

  Map<String, dynamic> memberStates = {};

  List<Map<String, dynamic>> allJobs = [];

  final live = <String, Map<String, dynamic>>{};

  String message = '';

  Timer? timer;

  bool loading = false;

  bool busy = false;

  bool loaded = false;

  String? snapshotSignature;

  int pollTick = 0;

  int? nextBefore;

  int historyLimit = 20;

  String tab = 'posts';

  String? artifact;

  String? error;

  OrganizationCommand? pending;
  StreamSubscription? connectionSubscription;
  int generation = -1;

  @override
  void initState() {
    super.initState();
    generation = connection.generation;
    connectionSubscription = connection.stream.listen((_) {
      if (!mounted) return;
      if (generation != connection.generation || !connection.state.connected) {
        generation = connection.generation;
        setState(() {
          group = null;
          profiles = [];
          jobs = [];
          memberStates = {};
          allJobs = [];
          live.clear();
          loaded = false;
          snapshotSignature = null;
          pending = null;
          error = null;
          nextBefore = null;
          message = '';
        });
      }
      if (connection.state.connected) refresh();
    });

    connection.notificationRevision.addListener(notificationRefresh);

    refresh();

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final active = jobs.any((j) => _activeJobStates.contains(j['state']));

      final interval = active && tab == 'posts' ? 1 : 10;

      if (++pollTick % interval == 0) refresh();
    });
  }

  void notificationRefresh() {
    if (mounted) refresh();
  }

  @override
  void dispose() {
    connection.notificationRevision.removeListener(notificationRefresh);

    connectionSubscription?.cancel();
    timer?.cancel();

    super.dispose();
  }

  Future<void> refresh() async {
    if (loading || !connection.state.connected) return;

    loading = true;

    final epoch = connection.generation;

    try {
      final data = await connection.request('organizations/history', {
        'group_id': component.id,

        'limit': historyLimit,
      });

      if (!mounted || epoch != connection.generation) return;

      final current =
          List<Map<String, dynamic>>.from(
            data['groups'] ?? [],
          ).where((g) => g['id'] == component.id).firstOrNull ??
          data['group'] as Map<String, dynamic>?;

      final signature = jsonEncode(data);

      if (signature != snapshotSignature)
        setState(() {
          snapshotSignature = signature;

          group = current;

          if (jobs.length <= historyLimit)
            nextBefore = data['next_before'] as int?;

          memberStates = Map<String, dynamic>.from(data['member_states'] ?? {});

          allJobs = List<Map<String, dynamic>>.from(data['jobs']);

          profiles = List<Map<String, dynamic>>.from(data['profiles'])
              .where((p) => p['organization_id'] == current?['organization_id'])
              .toList();

          final older = jobs
              .where(
                (j) => !(data['jobs'] as List).any((n) => n['id'] == j['id']),
              )
              .toList();

          jobs = List<Map<String, dynamic>>.from(data['jobs'])
              .where(
                (j) =>
                    j['kind'] == 'discussion' && j['group_id'] == component.id,
              )
              .toList()
              .reversed
              .toList();

          jobs.addAll(older);

          loaded = true;

          if (pending == null) error = null;
        });

      if (current != null)
        connection.selectedOrganization.value =
            current['organization_id'] as String;

      final active = jobs
          .where((j) => _activeJobStates.contains(j['state']))
          .firstOrNull;

      if (tab == 'posts' && current != null && active != null) {
        try {
          final result = await connection.request('organizations/inspect', {
            'organization_id': current['organization_id'],

            'job_id': active['id'],

            'request_id':
                'group_stream_${DateTime.now().microsecondsSinceEpoch}',
          });

          if (mounted && epoch == connection.generation) {
            final previous = live[active['id']];

            // A file can briefly be incomplete while the facilitator rewrites it.

            // Keep the last valid draft/replies until the next valid document arrives.

            if ((result['contributions'] as List? ?? []).isEmpty &&
                previous != null) {
              result['contributions'] = previous['contributions'];
            }

            if ((result['artifact_draft'] as String? ?? '').isEmpty &&
                previous != null) {
              result['artifact_draft'] = previous['artifact_draft'];
            }

            if (jsonEncode(previous) != jsonEncode(result))
              setState(() => live[active['id'] as String] = result);
          }
        } catch (exception) {
          if (mounted && epoch == connection.generation) {
            setState(
              () => live[active['id'] as String] = {
                ...?live[active['id']],

                'inspection_error': exception.toString(),
              },
            );
          }
        }
      }
    } catch (exception) {
      if (mounted && epoch == connection.generation)
        setState(() => error = exception.toString());
    } finally {
      loading = false;
    }
  }

  Future<void> loadOlder() async {
    if (loading || nextBefore == null) return;

    final epoch = connection.generation;

    loading = true;

    try {
      final data = await connection.request('organizations/history', {
        'group_id': component.id,

        'before': nextBefore,
      });

      if (!mounted || epoch != connection.generation) return;

      setState(() {
        final ids = jobs.map((j) => j['id']).toSet();

        jobs.addAll(
          List<Map<String, dynamic>>.from(data['jobs'])
              .where((j) => j['kind'] == 'discussion' && !ids.contains(j['id']))
              .toList()
              .reversed,
        );

        nextBefore = data['next_before'] as int?;
      });
    } catch (exception) {
      if (mounted) setState(() => error = exception.toString());
    } finally {
      loading = false;
    }
  }

  Future<void> submit(
    String action,

    Map<String, dynamic> body, {

    bool retry = false,
  }) async {
    if (busy ||
        group == null ||
        !connection.state.connected ||
        (!retry && pending != null) ||
        (retry && pending == null))
      return;

    final epoch = connection.generation;

    pending = retry
        ? pending
        : OrganizationCommand(action, {
            ...body,

            'organization_id': group!['organization_id'],
          });

    setState(() {
      busy = true;

      error = null;
    });

    try {
      await pending!.execute(connection);

      if (!mounted || epoch != connection.generation) return;

      final removed = pending!.action == 'remove_group';

      pending = null;

      if (action == 'group' || removed)
        await connection.request('organizations/directory');

      await refresh();

      if (removed && mounted) navigate('/organization');

      if (action == 'discuss') setState(() => message = '');
    } catch (exception) {
      if (mounted && epoch == connection.generation)
        setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit() async {
    final epoch = connection.generation;
    final v = await groupForm(profiles, group);
    if (v != null && mounted && epoch == connection.generation)
      await submit('group', v);
  }

  Future<void> managePreparation(Json job, bool retry) async {
    final epoch = connection.generation;
    if (await confirm(
          retry
              ? 'Retry inspected session preparation?'
              : 'Cancel waiting meeting?',
          retry
              ? 'Inspect and repair member sessions first. This retries preparation only. Submitted discussions must recover artifacts instead.'
              : 'No discussion prompt has been sent. Cancel this waiting meeting and release its scheduling reservation.',
        ) &&
        mounted &&
        epoch == connection.generation)
      await submit(retry ? 'retry_discussion' : 'cancel_discussion', {
        'job_id': job['id'],
        'inspected': true,
      });
  }

  Future<void> realignSession(Json job, Json mismatch, bool force) async {
    final epoch = connection.generation;
    if (!await confirm(
      force ? 'Force realign session?' : 'Realign session?',
      'Session project: ${mismatch['session_project']}\nCurrent project: ${mismatch['configured_project']}\n${force ? 'Stops even a working or blocked stale session after preserving visible output.' : 'Archives and closes only a verified idle session.'} Launches a fresh session from the current profile, preserving checkout files. Other jobs and ambiguous identities prevent closure. Unsubmitted discussion resumes automatically when members are ready.',
    ))
      return;

    if (mounted && epoch == connection.generation)
      await submit('realign_discussion_session', {
        'job_id': job['id'],
        'run_id': mismatch['run_id'],
        'expected_project': mismatch['configured_project'],
        'expected_alias': mismatch['alias'],
        'inspected': true,
        'force': force,
      });
  }

  Future<void> respondToBlock(Json stream) async {
    final epoch = connection.generation;
    if (await confirm(
          'Respond to ${stream['name']}',
          'Review the terminal request and selected option:\n${stream['output'] ?? ''}\nConfirm sends Enter. For artifact requests, select Allow once first. Saved permission policy is unchanged.',
        ) &&
        mounted &&
        epoch == connection.generation)
      await submit('input', {
        'profile_id': stream['profile_id'],
        'key': 'enter',
        'console_token': stream['console_token'],
      });
  }

  Future<void> export(Json job, bool download) async {
    try {
      if (download) {
        await downloadText(
          '${job['result']}',
          'discussion-artifact-${job['id']}.md',
        );
      } else {
        await copyText(
          '${job['result']}',
          filename: 'discussion-artifact-${job['id']}.md',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Export failed: $e');
    }
  }

  Future<void> downloadTranscript(Json job) async {
    final epoch = connection.generation;

    try {
      final result = await connection.request('organizations/transcript', {
        'organization_id': job['organization_id'],
        'job_id': job['id'],
        'request_id': 'transcript_${DateTime.now().microsecondsSinceEpoch}',
      });
      if (mounted && epoch == connection.generation)
        await downloadText('${result['content']}', 'discussion.json');
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() => error = '$e');
    }
  }

  Component liveDiscussion(Json job) {
    final data = live[job['id']] ?? <String, dynamic>{};

    return details('Live discussion', [
      if (data['inspection_error'] != null)
        prose('Live output unavailable: ${data['inspection_error']}'),

      for (final part in records(data['contributions']))
        card('${part['name']} · Round ${part['round']}', [
          pre(part['content']),
        ]),

      if ('${data['artifact_draft'] ?? ''}'.isNotEmpty)
        details('Artifact draft · Not finalized', [
          pre(data['artifact_draft']),
        ]),

      for (final stream in records(data['streams']))
        details('${stream['name']} · ${stream['status']}', [
          SnapshotTerminal(
            '${stream['error'] ?? stream['output'] ?? ''}',
            key: ValueKey('${job['id']}-${stream['profile_id']}'),
          ),

          if (stream['input_result'] is Map)
            prose(
              'Terminal response: ${stream['input_result']['state']} ${stream['input_result']['error'] ?? ''}',
            ),

          if (stream['status'] == 'blocked')
            row([
              if (stream['console_token'] != null)
                button(
                  'Respond to permission or question',
                  () => respondToBlock(stream),
                  disabled: busy || pending != null,
                ),

              for (final key in ['up', 'down', 'tab', 'enter', 'esc', 'ctrl+c'])
                button(
                  key,
                  () => submit('input', {
                    'profile_id': stream['profile_id'],
                    'key': key,
                    if (stream['console_token'] != null)
                      'console_token': stream['console_token'],
                  }),
                  disabled: busy || pending != null,
                ),
            ]),
        ]),
    ]);
  }

  Component discussion(Json job) => card('Discussion · ${job['created_at']}', [
    badge('${job['state']}'),
    prose(job['prompt'] ?? 'Started a discussion with the group.'),

    details('Discussion context', [
      pre(job['group']?['description'] ?? ''),
      prose(
        'Members: ${(job['runs'] as List? ?? []).map((r) => r['profile']?['name'] ?? r['profile_id']).join(', ')}',
      ),
    ]),

    if (job['progress'] != null) prose(job['progress']),
    if (job['error'] != null) prose(job['error']),

    for (final mismatch in records(job['project_mismatches']))
      card('${mismatch['name']}: project mismatch', [
        pre(
          'Session: ${mismatch['session_project']}\nConfigured: ${mismatch['configured_project']}\nGroup target: ${mismatch['expected_project']}',
        ),

        if (mismatch['recovery_pending'] == true)
          prose(
            'Archived session awaits relaunch: ${mismatch['recovery_error'] ?? ''}',
          ),

        if (mismatch['repairable'] != true)
          prose(
            'Update agent/group settings first. Task-owned or starting sessions require inspection.',
          ),

        if (connection.operator.value['role'] == 'admin' &&
            mismatch['repairable'] == true &&
            ['needs_attention', 'uncertain'].contains(job['state']))
          row([
            button(
              'Archive and relaunch in current project',
              () => realignSession(job, mismatch, false),
              disabled: busy || pending != null,
            ),
            button(
              'Force realign session',
              () => realignSession(job, mismatch, true),
              disabled: busy || pending != null,
            ),
          ]),
      ]),

    if (connection.operator.value['role'] == 'admin' &&
        job['preparation_version'] == 1 &&
        job['discussion_submitted_at'] == null &&
        [
          'waiting_for_members',
          'queued',
          'needs_attention',
          'uncertain',
        ].contains(job['state']))
      row([
        if (['needs_attention', 'uncertain'].contains(job['state']))
          button(
            'Retry inspected preparation',
            () => managePreparation(job, true),
            disabled: busy || pending != null,
          ),
        button(
          'Cancel waiting meeting',
          () => managePreparation(job, false),
          disabled: busy || pending != null,
        ),
      ]),

    if (['needs_attention', 'uncertain'].contains(job['state']) &&
        (job['discussion_submitted_at'] != null ||
            job['preparation_version'] == null))
      button(
        'Recover saved artifact',
        () => submit('recover', {'job_id': job['id']}),
        disabled: busy || pending != null,
      ),

    if (job == jobs.firstOrNull && _activeJobStates.contains(job['state']))
      liveDiscussion(job),

    for (final contribution in records(job['contributions']))
      details('${contribution['name']} · Round ${contribution['round']}', [
        pre(contribution['content']),
      ]),

    if ('${job['result'] ?? ''}'.isNotEmpty)
      button(
        'View artifact',
        () => setState(() {
          tab = 'artifacts';
          artifact = '${job['id']}';
        }),
      ),
  ]);

  @override
  Component build(BuildContext context) {
    if (!connection.state.connected)
      return card('Group', [
        button('Connect on the dashboard', () => navigate('/')),
      ]);

    if (group == null)
      return card('Group', [
        prose(error ?? (loaded ? 'Group not found.' : 'Loading group…')),
        button('Refresh', refresh),
      ]);

    final archived = group!['removed_at'] != null;

    final members = List<String>.from(group!['members'] ?? []);

    final occupied = allJobs.any(
      (j) =>
          ['queued', 'running', 'waiting_for_input'].contains(j['state']) &&
          (j['participants'] as List? ?? [j['profile_id']]).any(
            members.contains,
          ),
    );

    final disabled = busy || pending != null || occupied || archived;

    return el('div', [
      card('# ${group!['name']}', [
        details('Purpose and instructions', [pre(group!['description'])]),
        badge('${members.length} members'),

        button(
          'Project knowledge',
          () => navigate('/knowledge/${group!['organization_id']}'),
        ),

        row([
          button(
            'Edit group',
            edit,
            disabled: busy || pending != null || archived,
          ),
          button('Remove group', () async {
            final epoch = connection.generation;
            if (await confirm(
                  'Remove ${group!['name']}?',
                  'Removes this group and closes its facilitator terminal. Member agents remain. History, artifacts and worktree files are preserved.',
                ) &&
                mounted &&
                epoch == connection.generation)
              await submit('remove_group', {'group_id': component.id});
          }, disabled: disabled),
          button(
            'Start discussion',
            () => submit('discuss', {'group_id': component.id}),
            disabled: disabled,
            primary: true,
          ),
        ]),

        if (archived)
          prose(
            'Archived group · Saved discussions and downloads remain available.',
          ),
      ]),

      row([
        for (final item in {
          'posts': 'Posts',
          'artifacts': 'Artifacts',
          'proposals': 'Proposals',
          'settings': 'Settings',
          'members': 'Members',
          'about': 'About',
        }.entries)
          button(
            item.value,
            () => setState(() {
              tab = item.key;
              artifact = null;
            }),
            primary: tab == item.key,
          ),
      ]),

      if (error != null) prose(error),
      if (pending != null && !busy)
        row([
          button(
            'Retry same request',
            () => submit(pending!.action, const {}, retry: true),
          ),
          button(
            'Dismiss request',
            () => setState(() {
              pending = null;
              error = null;
            }),
          ),
        ]),

      if (tab == 'posts') ...[
        if (!archived)
          card('Message the group', [
            textarea(
              'Ask the group agent to coordinate its members',
              message,
              (v) => message = v,
            ),
            button(
              'Send to group',
              () {
                final value = message.trim();
                if (value.isNotEmpty && value.length <= 8000)
                  submit('discuss', {
                    'group_id': component.id,
                    'prompt': value,
                  });
              },
              disabled: disabled,
              primary: true,
            ),
          ]),

        if (jobs.isEmpty) prose('No discussions yet.'),
        for (final job in jobs) discussion(job),

        if (nextBefore != null)
          button('Load older discussions', loadOlder, disabled: loading),
      ],

      if (tab == 'artifacts') ...[
        if (artifact != null)
          button('Show all artifacts', () => setState(() => artifact = null)),

        if (!jobs.any((j) => '${j['result'] ?? ''}'.isNotEmpty))
          prose('Artifacts appear here after a discussion completes.'),

        for (final job in jobs.where(
          (j) =>
              '${j['result'] ?? ''}'.isNotEmpty &&
              (artifact == null || j['id'] == artifact),
        ))
          card('Discussion artifact · ${job['created_at']}', [
            pre(job['result']),
            row([
              if (job['task_id'] != null)
                button(
                  'Review task and follow-up proposals',
                  () => navigate('/tasks/${job['task_id']}'),
                ),
              button('Copy Markdown', () => export(job, false)),
              button('Download Markdown', () => export(job, true)),
              button('Download discussion.json', () => downloadTranscript(job)),
              button('Back to posts', () => setState(() => tab = 'posts')),
            ]),
          ]),
      ],

      if (tab == 'members') ...[
        prose(
          'Turn on an offline member to launch its saved persona. Active members are on. Uncertain runs need inspection from the organization chart.',
        ),

        for (final id in members)
          card(
            '${profiles.where((p) => p['id'] == id).firstOrNull?['name'] ?? id}',
            [
              prose(
                '${profiles.where((p) => p['id'] == id).firstOrNull?['role'] ?? ''} · ${memberStates[id]?['status'] ?? 'unknown'}',
              ),

              button(
                memberStates[id]?['active'] == true ? 'On' : 'Turn on',
                () async {
                  final run = memberStates[id]?['run_id'];
                  if (run != null) {
                    await submit('release', {'job_id': run});
                    if (pending != null || !mounted) return;
                  }
                  await submit('launch', {'profile_id': id});
                },
                disabled:
                    busy ||
                    archived ||
                    pending != null ||
                    memberStates[id]?['active'] == true ||
                    ![
                      'off',
                      'stopped',
                      'exited',
                    ].contains(memberStates[id]?['status']),
              ),
            ],
          ),
      ],

      if (tab == 'settings') ...[
        card('Group settings', [
          prose(
            'Automatic queueing: ${group!['create_tasks'] == true ? 'on' : 'off'}. Outcome reviews: ${group!['notify_outcomes'] != false ? 'on' : 'off'}. Read-only discussion: ${group!['read_only'] != false ? 'on' : 'off'}. Scope: ${group!['review_scope'] ?? 'topic'}. Members retain individual permissions.',
          ),
          button(
            'Edit group settings',
            edit,
            disabled: busy || archived || pending != null,
          ),
        ]),
        OrganizationAutomation(organizationId: '${group!['organization_id']}'),
      ],

      if (tab == 'proposals') ...[
        prose(
          'Creation and queueing outcomes are recorded per discussion. Skipped proposals have not become tasks.',
        ),

        for (final job in jobs)
          for (final p in records(job['proposal_details']))
            card('${p['title']}', [
              badge('${p['status'] ?? 'Awaiting evaluation'}'),
              prose(
                'Discussion: ${job['id']} · Assignee: ${profiles.where((profile) => profile['id'] == p['profile_id']).firstOrNull?['name'] ?? p['profile_id']}',
              ),
              if ('${p['reason'] ?? ''}'.isNotEmpty) prose(p['reason']),
              if ([
                'true',
                'yes',
              ].contains('${p['needs_review']}'.toLowerCase()))
                prose('Operator review required before execution.'),
              details('Acceptance criteria and required checks', [
                pre(p['description']),
              ]),
              if (p['task_id'] != null)
                button(
                  'Open created task',
                  () => navigate('/tasks/${p['task_id']}'),
                ),
            ]),
        if (nextBefore != null)
          button('Load older proposals', loadOlder, disabled: loading),
        button('View limits', () => setState(() => tab = 'settings')),
      ],

      if (tab == 'about')
        card('About this group', [
          pre(group!['description']),
          prose(
            'This group has its own Herdr conversation. Its agent coordinates members and synthesizes discussion artifacts, choosing rounds and follow-ups. Posts and artifacts preserve the description and members used for that discussion. Review recommendations before action.',
          ),
        ]),
    ]);
  }
}
