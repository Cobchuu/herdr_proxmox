import 'snapshot_terminal.dart';
import 'dart:async';

import '../services.dart';

import '../ui.dart';

import 'org_forms.dart';

Duration agentConsoleRefreshInterval(String? status) => switch (status) {
  'working' || 'running' || 'busy' || 'thinking' => const Duration(seconds: 1),

  'idle' || 'done' => const Duration(seconds: 5),

  _ => const Duration(seconds: 2),
};

class AgentConsolePage extends StatefulComponent {
  const AgentConsolePage({super.key, required this.id});

  final String id;

  @override
  State<AgentConsolePage> createState() => _AgentConsolePageState();
}

class _AgentConsolePageState extends State<AgentConsolePage> {
  DashboardBloc get connection => dashboardConnection;

  Timer? timer;

  StreamSubscription? subscription;

  Map<String, dynamic>? profile;

  Map<String, dynamic>? inspection;

  List<Map<String, dynamic>> jobs = [];

  String? error;

  String? responseError;

  String? inputJob;

  /// True only while a submitted response is still being delivered, so the

  /// snapshot poll stops once its job state has settled.

  bool trackDelivery = false;

  /// The reviewed prompt a pending response belongs to, and that response's

  /// command. A lost response must replay the same request ID, even when a new

  /// inspection shows a different prompt. New keys wait until it is reconciled.

  OrganizationCommand? pendingInput;

  DateTime? metadataReadAt;

  int generation = -1;

  bool loading = false;

  bool sending = false;

  bool showDraft = false;

  bool followOutput = true;

  bool scrollingToBottom = false;

  @override
  void initState() {
    super.initState();

    generation = connection.generation;

    subscription = connection.stream.listen((_) {
      if (!mounted) return;

      if (generation != connection.generation || !connection.state.connected) {
        generation = connection.generation;

        setState(() {
          profile = null;

          inspection = null;

          jobs = [];

          inputJob = null;

          responseError = null;

          pendingInput = null;

          trackDelivery = false;

          metadataReadAt = null;
        });
      } else {
        refresh();
      }
    });

    refresh();
  }

  void followLatestOutput() {}

  @override
  void dispose() {
    timer?.cancel();

    subscription?.cancel();

    super.dispose();
  }

  Future<void> refresh() async {
    if (loading || sending || !connection.state.connected) return;

    timer?.cancel();

    loading = true;

    final epoch = connection.generation;

    try {
      // Read the full snapshot to discover the profile, observe response

      // delivery, and refresh cached metadata once a minute. The frequent

      // terminal reads use the narrower inspect endpoint.

      if (profile == null ||
          trackDelivery ||
          metadataReadAt == null ||
          DateTime.now().difference(metadataReadAt!) >=
              const Duration(minutes: 1)) {
        final data = Map<String, dynamic>.from(
          await connection.request('organizations/state'),
        );

        if (!mounted || epoch != connection.generation) return;

        final current = List<Map<String, dynamic>>.from(
          data['profiles'],
        ).where((p) => p['id'] == component.id).firstOrNull;

        final records = List<Map<String, dynamic>>.from(data['jobs'])
            .where(
              (j) =>
                  j['profile_id'] == component.id ||
                  (j['participants'] as List? ?? []).contains(component.id),
            )
            .toList();

        setState(() {
          profile = current;

          metadataReadAt = DateTime.now();

          jobs = records;

          final delivery = records
              .where((j) => j['id'] == inputJob)
              .firstOrNull;

          if (delivery != null &&
              !['queued', 'running'].contains(delivery['state'])) {
            trackDelivery = false;
          }
        });

        if (current == null) {
          setState(() {
            inspection = null;

            error = 'Agent was not found.';
          });

          return;
        }

        connection.selectedOrganization.value =
            current['organization_id'] as String;
      }

      final current = profile;

      if (current == null) return;

      final result = await OrganizationCommand('inspect', {
        'organization_id': current['organization_id'],

        'profile_id': component.id,
      }).execute(connection);

      if (!mounted || epoch != connection.generation) return;

      setState(() {
        inspection = Map<String, dynamic>.from(result);

        error = null;
      });

      followLatestOutput();
    } catch (e) {
      if (mounted && epoch == connection.generation) {
        setState(() {
          error = '$e';

          inspection = null;
        });
      }
    } finally {
      loading = false;

      if (mounted && connection.state.connected) {
        timer = Timer(
          agentConsoleRefreshInterval(inspection?['status'] as String?),

          refresh,
        );
      }
    }
  }

  Future<void> sendKey(String key) async {
    if (sending ||
        pendingInput != null ||
        inspection?['status'] != 'blocked' ||
        inspection?['console_token'] == null ||
        !connection.state.connected)
      return;

    pendingInput = OrganizationCommand('input', {
      'organization_id': profile!['organization_id'],

      'profile_id': component.id,

      'key': key,

      'console_token': inspection!['console_token'],
    });

    await submitPendingInput();
  }

  Future<void> submitPendingInput() async {
    if (sending || pendingInput == null || !connection.state.connected) return;

    final epoch = connection.generation;

    setState(() {
      sending = true;

      responseError = null;
    });

    try {
      final result = await pendingInput!.execute(connection);

      if (!mounted || epoch != connection.generation) return;

      setState(() {
        inputJob = result['id'] as String;

        trackDelivery = true;

        inspection = null;

        pendingInput = null;
      });
    } catch (e) {
      // Keep the pending command: the gateway may have applied it and only the

      // response was lost, so the retry must carry the same request ID.

      if (mounted && epoch == connection.generation) {
        setState(() {
          // A 4xx admission refusal did not create an input job. A transport

          // failure or 5xx cannot establish that, so keep its replay identity.

          if (e is DashboardRequestException &&
              e.statusCode >= 400 &&
              e.statusCode < 500) {
            pendingInput = null;
          }

          responseError = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }

    // The gateway queues input; its job state is the delivery evidence.

    await refresh();
  }

  @override
  Component build(BuildContext context) {
    final blocked = inspection?['status'] == 'blocked';

    final delivery = jobs.where((j) => j['id'] == inputJob).firstOrNull;

    final awaiting =
        inputJob != null &&
        (delivery == null || ['queued', 'running'].contains(delivery['state']));

    final canRespond =
        blocked &&
        !sending &&
        pendingInput == null &&
        !awaiting &&
        connection.state.connected &&
        inspection?['console_token'] != null;

    final draft = '${inspection?['reply_draft'] ?? ''}';

    return card('${profile?['name'] ?? 'Agent'} console', [
      if (profile != null)
        prose('${profile!['role']} · ${profile!['runtime']}'),

      if (error != null) prose(error),
      if (responseError != null) prose(responseError),

      if (pendingInput != null)
        row([
          prose(
            'Delivery of ${pendingInput!.body?['key']} is unknown. Recheck before sending another key.',
          ),
          button(
            'Recheck pending response',
            submitPendingInput,
            disabled: sending || !connection.state.connected,
          ),
        ]),

      if (delivery != null)
        prose(
          'Terminal response: ${delivery['state']} ${delivery['error'] ?? ''}',
        ),

      if (blocked)
        card('Requires attention', [
          prose(
            'Select Allow or Reject in the console prompt, then confirm. Escape cancels where supported.',
          ),

          row([
            for (final key in [
              'up',
              'down',
              'tab',
              'shift+tab',
              'enter',
              'esc',
            ])
              button(
                key == 'enter' ? 'Confirm selected Allow / Reject' : key,
                () => sendKey(key),
                disabled: !canRespond,
              ),
          ]),
        ]),

      row([
        badge('${inspection?['status'] ?? 'unavailable'}'),
        button('Refresh console', refresh, disabled: sending),
        if (draft.isNotEmpty)
          button(
            showDraft ? 'Live console' : 'Current reply draft',
            () => setState(() => showDraft = !showDraft),
          ),
      ]),

      prose(
        'Refreshes every second while working, every 5 seconds while idle, and every 2 seconds while awaiting attention. Retained output may omit earlier work.',
      ),

      showDraft && draft.isNotEmpty
          ? pre(draft)
          : SnapshotTerminal(
              '${inspection?['output'] ?? 'No live session output available.'}',
            ),
    ]);
  }
}
