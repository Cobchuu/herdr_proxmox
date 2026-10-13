import 'dart:async';

import 'dart:math';

import '../services.dart';

import '../ui.dart';

import 'org_forms.dart';

String newRequestId() =>
    '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0x7fffffff)}';

class OrganizationAutomation extends StatefulComponent {
  const OrganizationAutomation({super.key, required this.organizationId});

  final String organizationId;

  @override
  State<OrganizationAutomation> createState() => _OrganizationAutomationState();
}

class _OrganizationAutomationState extends State<OrganizationAutomation> {
  DashboardBloc get connection => dashboardConnection;

  Map<String, dynamic>? policy;

  Map<String, dynamic>? pending;

  String? error;

  bool busy = false;

  int generation = -1;

  StreamSubscription? subscription;

  @override
  void initState() {
    super.initState();

    generation = connection.generation;

    subscription = connection.stream.listen((_) {
      if (!mounted) return;

      if (generation != connection.generation || !connection.state.connected) {
        generation = connection.generation;

        setState(() {
          policy = null;

          pending = null;

          error = null;
        });
      }

      if (policy == null && connection.state.connected) refresh();
    });

    connection.notificationRevision.addListener(refresh);

    refresh();
  }

  @override
  void dispose() {
    subscription?.cancel();

    connection.notificationRevision.removeListener(refresh);

    super.dispose();
  }

  Future<void> refresh() async {
    if (busy || !connection.state.connected) return;

    final epoch = connection.generation;

    setState(() => busy = true);

    try {
      final result = await connection.request(
        'organizations/automation?organization_id=${Uri.encodeQueryComponent(component.organizationId)}',
      );

      if (mounted && epoch == connection.generation)
        setState(() {
          policy = Map<String, dynamic>.from(result['policy']);

          error = null;
        });
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() => busy = false);

        if (epoch != connection.generation && connection.state.connected)
          refresh();
      }
    }
  }

  Future<void> edit() async {
    final epoch = connection.generation;

    final chosen = await editOrganizationAutomation(policy!);

    if (!mounted || epoch != connection.generation || chosen == null) return;

    pending = {
      'organization_id': component.organizationId,

      ...chosen,

      'request_id': newRequestId(),
    };

    await save();
  }

  Future<void> save() async {
    if (busy ||
        pending == null ||
        !connection.state.connected ||
        connection.operator.value['role'] != 'admin')
      return;

    final epoch = connection.generation;

    setState(() {
      busy = true;

      error = null;
    });

    try {
      final result = await connection.request('tasks/automation', pending);

      if (mounted && epoch == connection.generation)
        setState(() {
          policy = Map<String, dynamic>.from(result['policy']);

          pending = null;
        });
    } catch (e) {
      if (mounted && epoch == connection.generation)
        setState(() {
          error = '$e';

          if (e is DashboardRequestException &&
              e.statusCode >= 400 &&
              e.statusCode < 500)
            pending = null;
        });
    } finally {
      if (mounted) {
        setState(() => busy = false);

        if (epoch != connection.generation && connection.state.connected)
          refresh();
      }
    }
  }

  @override
  Component build(BuildContext context) {
    final admin =
        connection.state.connected &&
        connection.operator.value['role'] == 'admin';

    return card('Organization automation & limits', [
      prose(
        'Shared by every group. Valid proposals are retained as drafts; limits control automatic queueing. Changing limits does not reprocess finalized discussions.',
      ),

      if (error != null) prose(error),

      if (policy != null) ...[
        for (final entry in policy!.entries)
          prose('${entry.key.replaceAll('_', ' ')}: ${entry.value}'),
      ],

      row([
        button(
          'Edit policy',
          edit,
          disabled: !admin || policy == null || busy || pending != null,
        ),
        button('Refresh limits', refresh, disabled: busy),
        if (pending != null)
          button('Retry same policy save', save, disabled: !admin || busy),
      ]),
    ]);
  }
}

Future<Json?> editOrganizationAutomation(Json policy) async {
  final defaults = <String, dynamic>{
    'auto_queue_proposals': false,
    'paused': false,
    'reap_finished_sessions': false,
    'reap_orphaned_panes': false,
    'max_per_meeting': 1,
    'max_open_per_agent': 2,
    'max_follow_up_depth': 1,
    'daily_cap': 5,
    'max_active_sessions': 0,
    'max_active_meetings': 0,
    'daily_session_cap': 0,
    ...policy,
  };

  final maxima = {
    'max_per_meeting': 10,
    'max_open_per_agent': 50,
    'max_follow_up_depth': 10,
    'daily_cap': 100,
    'max_active_sessions': 50,
    'max_active_meetings': 10,
    'daily_session_cap': 500,
  };

  final labels = {
    'auto_queue_proposals': 'Automatically queue qualifying follow-ups',
    'paused': 'Pause automatic follow-up',
    'reap_finished_sessions':
        'Archive and close finished idle sessions automatically',
    'reap_orphaned_panes': 'Reclaim proven empty orphaned panes',
    'max_per_meeting': 'Max automatic tasks per meeting',
    'max_open_per_agent': 'Max open tasks per agent',
    'max_follow_up_depth': 'Max follow-up depth',
    'daily_cap': 'Daily task limit',
    'max_active_sessions': 'Max active sessions',
    'max_active_meetings': 'Max active meetings',
    'daily_session_cap': 'Daily session starts',
  };

  final result = await editRecord(
    'Organization automation & limits',
    defaults,
    labels,
    flags: {
      'auto_queue_proposals',
      'paused',
      'reap_finished_sessions',
      'reap_orphaned_panes',
    },
    extra: (v) => [
      prose(
        'Valid proposals remain drafts when queueing is disabled or limits are reached. Publishing, merging and deployment remain manual. Pausing leaves queued work queued. A session budget of 0 disables that limit. Finished-session cleanup retains archives and never closes working agents; orphan cleanup requires verified empty panes.',
      ),
    ],
    validate: (v) {
      for (final entry in maxima.entries) {
        final n = int.tryParse('${v[entry.key]}');
        if (n == null || n < 0 || n > entry.value)
          return '${labels[entry.key]} must be a whole number from 0 to ${entry.value}.';
      }
      return null;
    },
  );

  if (result == null) return null;

  return {
    for (final key in labels.keys)
      key: maxima.containsKey(key) ? int.parse('${result[key]}') : result[key],
  };
}
