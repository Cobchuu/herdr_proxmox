import 'snapshot_terminal.dart';
import 'dart:async';

import 'dart:convert';

import '../services.dart';

import '../ui.dart';

import '../navigation.dart';

import 'org_forms.dart';

/// Delivery stages are evidence, not proof of a completed turn. The labels keep

/// an acknowledged CLI return distinct from a verified reply file.

const deliveryStages = <String, String>{
  'submitting': 'Submitting the prompt',

  'command_returned': 'CLI returned (acknowledgment only)',

  'session_idle_reply_pending': 'Waiting for the reply file',

  'reply_verified': 'Reply verified',

  'not_submitted': 'Not submitted',

  'unknown': 'Unknown',
};

String deliveryLabel(Object? stage) {
  final value = '${stage ?? ''}';

  if (value.isEmpty) return 'No delivery evidence';

  return deliveryStages[value] ?? value;
}

class CollaborationPanel extends StatefulComponent {
  const CollaborationPanel({
    super.key,

    required this.organization,

    required this.profiles,

    this.onOpenGroup,
  });

  final Map<String, dynamic> organization;

  final List<Map<String, dynamic>> profiles;

  final void Function(String)? onOpenGroup;

  @override
  State<CollaborationPanel> createState() => _CollaborationPanelState();
}

class _CollaborationPanelState extends State<CollaborationPanel> {
  DashboardBloc get connection => dashboardConnection;

  String prompt = '';

  List<Map<String, dynamic>> groups = [];

  List<Map<String, dynamic>> jobs = [];

  String? profile;

  String? error;

  String output = '';

  String status = '';

  String draft = '';

  String? draftJob;

  bool busy = false;

  bool polling = false;

  OrganizationCommand? pending;
  StreamSubscription? connectionSubscription;
  int generation = -1;

  String? snapshotSignature;

  int pollTick = 0;

  Timer? timer;

  @override
  void initState() {
    super.initState();
    generation = connection.generation;
    connectionSubscription = connection.stream.listen((_) {
      if (!mounted) return;
      if (generation != connection.generation || !connection.state.connected) {
        generation = connection.generation;
        setState(() {
          groups = [];
          jobs = [];
          profile = null;
          output = '';
          status = '';
          draft = '';
          draftJob = null;
          snapshotSignature = null;
          pending = null;
          error = null;
          prompt = '';
        });
      }
      if (connection.state.connected) refresh();
    });

    refresh();

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (profile != null || ++pollTick % 10 == 0) refresh();
    });
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    timer?.cancel();

    super.dispose();
  }

  Map<String, dynamic> body(Map<String, dynamic> values) => OrganizationCommand(
    'inspect',

    {...values, 'organization_id': component.organization['id']},
  ).body!;

  Future<void> refresh() async {
    if (polling || !connection.state.connected) return;

    polling = true;

    final epoch = connection.generation;

    final selected = profile;

    try {
      final data = await connection.request('organizations/activity', {
        'organization_id': component.organization['id'],
      });

      if (!mounted || epoch != connection.generation) return;

      final signature = jsonEncode(data);

      if (snapshotSignature != signature)
        setState(() {
          snapshotSignature = signature;

          groups = List<Map<String, dynamic>>.from(data['groups'] ?? [])
              .where(
                (g) => g['organization_id'] == component.organization['id'],
              )
              .toList();

          jobs = List<Map<String, dynamic>>.from(data['jobs'])
              .where(
                (j) => j['organization_id'] == component.organization['id'],
              )
              .toList();
        });

      if (selected != null) {
        final result = await connection.request(
          'organizations/inspect',

          body({'profile_id': selected}),
        );

        if (mounted &&
            epoch == connection.generation &&
            selected == profile &&
            (output != result['output'] ||
                status != result['status'] ||
                draft != (result['reply_draft'] ?? '') ||
                draftJob != result['reply_job_id'] ||
                (error != null && pending == null))) {
          setState(() {
            output = result['output'] as String;

            status = result['status'] as String;

            draft = result['reply_draft'] as String? ?? '';

            draftJob = result['reply_job_id'] as String?;

            if (pending == null) error = null;
          });
        }
      }
    } catch (exception) {
      if (mounted && epoch == connection.generation)
        setState(() => error = exception.toString());
    } finally {
      polling = false;
    }
  }

  Future<void> submit(
    String action,

    Map<String, dynamic> values, {

    bool retry = false,
  }) async {
    if (busy ||
        !connection.state.connected ||
        (!retry && pending != null) ||
        (retry && pending == null))
      return;

    final epoch = connection.generation;

    if (!retry) {
      pending = OrganizationCommand(action, {
        ...values,

        'organization_id': component.organization['id'],
      });
    }

    setState(() {
      busy = true;

      error = null;
    });

    try {
      await pending!.execute(connection);

      if (!mounted || epoch != connection.generation) return;

      pending = null;

      if (action == 'chat') setState(() => prompt = '');

      await refresh();
    } catch (exception) {
      if (mounted && epoch == connection.generation)
        setState(() => error = exception.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> editGroup([Json? group]) async {
    final epoch = connection.generation;
    final v = await groupForm(component.profiles, group);
    if (v != null && mounted && epoch == connection.generation)
      await submit('group', v);
  }

  bool occupied(String id) => jobs.any(
    (j) =>
        ['queued', 'running'].contains(j['state']) &&
        (j['participants'] as List? ?? [j['profile_id']]).contains(id),
  );

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

  Component record(Json job) => card(
    '${job['kind'] == 'chat' ? 'Message' : job['group']?['name'] ?? 'Discussion'} · ${job['state']}',
    [
      if (job['prompt'] != null) pre('You: ${job['prompt']}'),
      if (job['progress'] != null) prose(job['progress']),
      if (job['error'] != null) prose(job['error']),

      if (job['delivery'] is Map)
        el('section', [
          prose('Delivery: ${deliveryLabel(job['delivery']['stage'])}'),
          if ('${job['delivery']['reply_name'] ?? ''}'.isNotEmpty)
            prose('Reply file: ${job['delivery']['reply_name']}'),
          if (job['delivery']['recovered'] == true)
            prose('Recovered from a saved reply; no terminal input was sent.'),
          for (final field in [
            'started_at',
            'returned_at',
            'checked_at',
            'verified_at',
          ])
            if ('${job['delivery'][field] ?? ''}'.isNotEmpty)
              prose('${field.replaceAll('_', ' ')}: ${job['delivery'][field]}'),
          prose('Job ${job['id']}'),
        ], classes: 'delivery-evidence'),

      if (job['kind'] == 'chat' &&
          ['needs_attention', 'uncertain'].contains(job['state']))
        button('Recover saved reply', () async {
          final epoch = connection.generation;
          if (await confirm(
                'Recover saved reply',
                'Confirm you inspected the original conversation and the agent is idle. Recovery reads the saved reply without resending the prompt.',
              ) &&
              mounted &&
              epoch == connection.generation)
            await submit('recover', {
              'job_id': job['id'],
              'chat': true,
              'inspected': true,
            });
        }, disabled: busy || pending != null),

      if ('${job['result'] ?? ''}'.isNotEmpty) ...[
        details(
          job['kind'] == 'chat'
              ? (job['result_format'] == 'markdown'
                    ? 'View agent reply'
                    : 'View earlier terminal snapshot')
              : 'View artifact',
          [pre(job['result'])],
        ),
        row([
          button('Copy Markdown', () => export(job, false)),
          button('Download Markdown', () => export(job, true)),
        ]),
      ],

      if ((job['contributions'] as List? ?? []).isNotEmpty)
        details('Discussion contributions', [
          for (final part in records(job['contributions']))
            card('${part['name']} · Round ${part['round']}', [
              pre(part['content']),
            ]),
        ]),
    ],
  );

  @override
  Component build(BuildContext context) => el('div', [
    card('Chat with an agent', [
      prose(
        'Launch the agent first. Replies contain the agent answer; terminal output is available separately.',
      ),

      select(
        'Agent',
        profile ?? '',
        {
          '': 'Select agent',
          for (final p in component.profiles) '${p['id']}': '${p['name']}',
        },
        (value) {
          if (busy) return;
          setState(() {
            profile = value.isEmpty ? null : value;
            output = '';
            status = '';
            draft = '';
            draftJob = null;
            error = null;
          });
          refresh();
        },
      ),

      textarea(
        'Ask a question or give instructions',
        prompt,
        (v) => prompt = v,
      ),

      button(
        'Send prompt',
        () {
          final value = prompt.trim();
          if (value.isNotEmpty && value.length <= 8000)
            submit('chat', {'profile_id': profile, 'prompt': value});
        },
        disabled:
            busy || pending != null || profile == null || occupied(profile!),
        primary: true,
      ),

      if (status.isNotEmpty) badge(status),
      if (status == 'blocked')
        prose(
          'Read the terminal request. Approval applies to the currently selected terminal option.',
        ),

      if (draftJob != null)
        details('Reply in progress', [
          pre(
            draft.isEmpty
                ? 'Waiting for the agent to write its answer…'
                : draft,
          ),
        ]),

      if (output.isNotEmpty)
        details('Live terminal output', [
          SnapshotTerminal(output, key: ValueKey(profile)),
        ]),

      if (profile != null && output.isNotEmpty)
        row([
          for (final key in ['up', 'down', 'tab', 'enter', 'esc', 'ctrl+c'])
            button(
              key,
              () => submit('input', {'profile_id': profile, 'key': key}),
              disabled: busy || pending != null || occupied(profile!),
            ),
        ]),

      for (final job in jobs.reversed.where(
        (j) => j['kind'] == 'chat' && j['profile_id'] == profile,
      ))
        record(job),
    ]),

    card('Discussion groups', [
      prose(
        'Choose 2–6 agents and a desired outcome. A dedicated facilitator coordinates members and saves the artifact. Launch members before starting.',
      ),

      button(
        'Create group',
        () => editGroup(),
        disabled: busy || pending != null,
      ),

      for (final group in groups)
        card('${group['name']}', [
          prose(group['description']),
          prose(
            'Members: ${(group['members'] as List? ?? []).map((id) => component.profiles.where((p) => p['id'] == id).firstOrNull?['name'] ?? id).join(', ')}',
          ),

          row([
            button('Open group', () {
              if (component.onOpenGroup != null) {
                component.onOpenGroup!('${group['id']}');
              } else {
                navigate('/groups/${group['id']}');
              }
            }),
            button(
              'Edit group',
              () => editGroup(group),
              disabled: busy || pending != null,
            ),
            button('Remove group', () async {
              final epoch = connection.generation;
              if (await confirm(
                    'Remove ${group['name']}?',
                    'Removes this group and closes its facilitator terminal. Members remain; history, artifacts and files are preserved.',
                  ) &&
                  mounted &&
                  epoch == connection.generation)
                await submit('remove_group', {'group_id': group['id']});
            }, disabled: busy || pending != null),
            button(
              'Start discussion',
              () => submit('discuss', {'group_id': group['id']}),
              disabled:
                  busy ||
                  pending != null ||
                  (group['members'] as List? ?? []).any(
                    (id) => occupied('$id'),
                  ),
              primary: true,
            ),
          ]),
        ]),
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

    for (final job in jobs.reversed.where((j) => j['kind'] == 'discussion'))
      record(job),
  ]);
}
