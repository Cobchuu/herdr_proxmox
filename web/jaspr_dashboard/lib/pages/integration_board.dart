import 'dart:math';
import 'operations_support.dart';

class IntegrationBoard extends StatefulComponent {
  const IntegrationBoard({super.key, required this.repository});
  final String repository;
  @override
  State<IntegrationBoard> createState() => _BoardState();
}

class _BoardState extends OperationsState<IntegrationBoard> {
  Map<String, dynamic> data = {}, validation = {};
  String? actionFailure, checked;
  bool refreshing = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (busy || refreshing || !connection.state.connected) return;
    final epoch = connection.generation;
    refreshing = true;
    try {
      final result = await connection.request('integration');
      Map<String, dynamic> validationData;
      try {
        validationData = Map<String, dynamic>.from(
          await connection.request('validation'),
        );
      } catch (e) {
        validationData = {'error': '$e'};
      }
      if (valid(epoch))
        setState(() {
          data = Map<String, dynamic>.from(result['coordination'] ?? {});
          validation = validationData;
          checked = result['checked'] as String?;
          error = null;
        });
    } catch (e) {
      if (valid(epoch)) setState(() => error = '$e');
    } finally {
      if (valid(epoch)) setState(() => refreshing = false);
    }
  }

  Future<void> action(String endpoint, Map<String, dynamic> body) async {
    if (busy || !connection.state.connected) return;
    final epoch = connection.generation;
    setState(() {
      busy = true;
      error = null;
      actionFailure = null;
    });
    try {
      await connection.request(endpoint, body);
      if (!valid(epoch)) return;
      await connection.request('organizations/directory');
    } catch (e) {
      if (valid(epoch)) setState(() => actionFailure = '$e');
    } finally {
      if (valid(epoch)) {
        setState(() => busy = false);
        await refresh();
      }
    }
  }

  String profileName(dynamic id) =>
      '${(connection.organizationDirectory.value['profiles'] as List? ?? []).where((p) => p['id'] == id).firstOrNull?['name'] ?? id}';
  String eventStatus(Map event) {
    if (event['state'] == 'validation_waived')
      return 'Merged · validation waived';
    if (event['state'] == 'validation_ready')
      return 'Merged · validation queued';
    if (event['state'] == 'validating') return 'Merged · validating';
    if (event['state'] == 'validation_pending' ||
        (event['state'] == 'blocked' &&
            event['verification']?['target_incorporated'] == true &&
            event['tests']?['status'] == 'not_run'))
      return 'Merged · validation pending';
    if (event['state'] == 'validation_failed' ||
        (event['state'] == 'blocked' &&
            event['verification']?['target_incorporated'] == true &&
            event['tests']?['status'] == 'failed'))
      return 'Merged · validation failed';
    return '${event['state']}';
  }

  String? validationRun(Map event) {
    final recorded = event['validation_run'];
    if (recorded is Map) return '${recorded['state'] ?? ''}';
    final match = (validation['runs'] as List? ?? [])
        .where((r) => r['event_id'] == event['id'])
        .firstOrNull;
    return match == null ? null : '${match['state'] ?? ''}';
  }

  Map? validationRecord(Map event) {
    final recorded = event['validation_run'];
    if (recorded is Map && recorded['run_id'] != null) return recorded;
    return (validation['runs'] as List? ?? [])
            .where((r) => r['event_id'] == event['id'])
            .firstOrNull
        as Map?;
  }

  Future<void> downloadLog(Map run) async {
    await perform((epoch) async {
      final content = await connection.text(
        'validation/log?id=${run['run_id']}',
      );
      if (!valid(epoch)) return;
      await downloadText(content, 'validation-${run['run_id']}.log');
      if (valid(epoch))
        setState(() => message = 'Validation log download started.');
    });
  }

  Future<void> recoverWorker(Map event, String mode) async {
    final epoch = connection.generation;
    if (!await confirm(
          mode == 'recover'
              ? 'Recover saved worker result'
              : 'Continue with validation only',
          'Inspect the original worker conversation first. Recovery requires the same session to be idle. Validation only also verifies the target is already incorporated; it never repeats the merge.',
          confirmLabel: 'I inspected the conversation',
        ) ||
        !valid(epoch))
      return;
    await action('integration/recover', {
      'id': event['id'],
      'job_id': event['job_id'],
      'mode': mode,
      'inspected': true,
    });
  }

  Future<void> repair(Map config, {required bool fresh}) async {
    final epoch = connection.generation;
    if (fresh &&
        !await confirm(
          'Create a fresh coordinator summary?',
          'Inspect the coordinator conversation first. The previous request must no longer be running. This retires the old report and queues a new summary of current evidence. It preserves audit history and does not replay merges. If the old run was released, the same profile will be relaunched.',
          confirmLabel: 'Inspected · create summary',
        ))
      return;
    if (!valid(epoch)) return;
    await action('integration/repair', {
      'repository': component.repository,
      'job_id': config['report_job_id'],
      'mode': fresh ? 'fresh' : 'recover',
      if (fresh) 'inspected': true,
    });
    if (valid(epoch) && actionFailure == null)
      setState(
        () => message = fresh
            ? 'Fresh summary requested. The gateway waits for the coordinator to be ready.'
            : 'Saved coordinator report recovered.',
      );
  }

  Future<void> guidance(Map event) async {
    final epoch = connection.generation;
    if (!admin || busy) return;
    if (!await confirm(
          'Repair worker guidance',
          'Inspect the worker first and confirm it is idle. Modified guidance is quarantined and rebuilt. This does not resend the job. Administrator access is required.',
          confirmLabel: 'I inspected the idle worker',
        ) ||
        !valid(epoch))
      return;
    await action('integration/guidance', {
      'id': event['id'],
      'inspected': true,
    });
  }

  Future<void> reviewBlockers(List events, bool enabled) async {
    final candidates = events
        .where(
          (e) => [
            'blocked',
            'deferred',
            'validation_pending',
            'validation_failed',
            'validation_waived',
          ].contains(e['state']),
        )
        .take(20)
        .toList();
    final selected = <String, String>{};
    var explanation = '';
    final epoch = connection.generation;
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    bool merged(Map e) =>
        e['verification']?['target_incorporated'] == true &&
        e['verification']?['conflicts'] == 0 &&
        e['verification']?['merging'] != true;
    String defaultAction(Map e) => merged(e)
        ? (enabled ? 'retry_validation' : 'waive_validation')
        : 'reconsider';
    final eligible = candidates.where((e) => merged(e) || enabled).toList();
    final approved = await showDialog<bool>(
      'Review integration blockers',
      (close) => stack([
        paragraph(
          'Approve actions for these commits and worktrees only. Missing tools remain missing; a waiver records skipped validation, never a test pass. No CLI permissions change.',
        ),
        toggle(
          'Select all eligible actions',
          eligible.isNotEmpty &&
              eligible.every((e) => selected.containsKey(e['id'])),
          (value) {
            selected.clear();
            if (value)
              for (final e in eligible) {
                selected[e['id']] = defaultAction(e);
              }
            refreshDialogs();
          },
        ),
        for (final e in candidates)
          card('${e['name']} · ${eventStatus(e)}', [
            codeText(
              '${e['path']} → ${e['target']}\n${e['reason'] ?? ''}\n${e['tests']?['summary'] ?? ''}${'${e['blocker_label'] ?? ''}'.isEmpty ? '' : '\nBlocker: ${e['blocker_label']}'}',
            ),
            toggle(
              'Approve this action',
              selected.containsKey(e['id']),
              (value) {
                if (value) {
                  selected[e['id']] = defaultAction(e);
                } else {
                  selected.remove(e['id']);
                }
                refreshDialogs();
              },
              disabled: !merged(e) && !enabled,
            ),
            if (selected.containsKey(e['id']))
              select(
                'Approved action',
                selected[e['id']]!,
                {
                  if (merged(e) && enabled)
                    'retry_validation': 'Run validation again',
                  if (merged(e))
                    'waive_validation': 'Accept validation gap (waiver)',
                  if (!merged(e) && enabled)
                    'reconsider': 'Ask worker to reassess blocker',
                },
                (value) {
                  selected[e['id']] = value;
                  refreshDialogs();
                },
              ),
          ]),
        paragraph(
          'Pinned toolchains are installed by the root service from Settings. Conflicts are reassessed by the worker; uncertain delivery and missing snapshots require separate inspection.',
        ),
        textarea(
          'Reason for approval (maximum 1,000 characters)',
          explanation,
          (value) {
            explanation = value.substring(0, min(value.length, 1000)).trim();
            refreshDialogs();
          },
        ),
        actions([
          button('Cancel', () => close(false)),
          button(
            'Approve selected actions',
            () => close(true),
            primary: true,
            disabled: selected.isEmpty || explanation.isEmpty,
          ),
        ]),
      ]),
    );
    if (approved != true || !valid(epoch)) return;
    await action('integration/blockers', {
      'request_id': id,
      'reason': explanation,
      'selections': [
        for (final e in candidates)
          if (selected.containsKey(e['id']))
            {
              'id': e['id'],
              'repository': e['repository'],
              'target': e['target'],
              'updated_at': e['updated_at'],
              'action': selected[e['id']],
            },
      ],
    });
  }

  Future<void> eventDetails(Map event) => showDialog<void>(
    '${event['name']} · ${eventStatus(event)}',
    (close) => stack([
      codeText(
        'Checkout: ${event['path']}\nTarget: ${event['target']}\nUpdated: ${displayTime(event['updated_at'])}\nReason: ${event['reason'] ?? ''}\nBlocker category: ${'${event['blocker_label'] ?? ''}'.isEmpty ? 'None recorded' : event['blocker_label']}\nValidation runner: ${validationRun(event) ?? 'Not run'}\nCheckpoint: ${event['checkpoint'] ?? ''}\nJob: ${event['job_id'] ?? 'Not submitted'}\nMerge mode: ${event['merge_mode'] ?? 'Not recorded'}\nGit verification: ${event['verification'] ?? 'Not recorded'}\nOperator approval: ${event['operator_approval'] ?? 'None'}\nTests (worker-reported): ${event['tests']?['status'] ?? 'Not reported'}\n${event['tests']?['summary'] ?? ''}\nRecovery: ${event['recovery']?['ref'] ?? 'Not created yet; required before merge delivery'}',
      ),
      actions([
        if (event['state'] == 'needs_attention' && event['job_id'] != null) ...[
          button('Recover saved result', () {
            close(null);
            recoverWorker(event, 'recover');
          }, disabled: busy),
          button('Continue validation only', () {
            close(null);
            recoverWorker(event, 'validate');
          }, disabled: busy),
        ],
        button('Repair worker guidance', () {
          close(null);
          guidance(event);
        }, disabled: busy || !admin),
        if (validationRun(event) != 'running')
          button(
            'Validate exact commit',
            () {
              close(null);
              action('validation/run', {'id': event['id']});
            },
            disabled: busy || '${event['target'] ?? ''}'.isEmpty,
          ),
        if (validationRecord(event) != null)
          button(
            'Download validation log',
            () => downloadLog(validationRecord(event)!),
            disabled: busy,
          ),
        button('Close', () => close(null)),
      ]),
    ]),
  );
  String recoveryCommand(Map event) =>
      'git worktree add --detach <new-recovery-folder> ${event['recovery']['ref']}^1\ngit -C <new-recovery-folder> restore --source=${event['recovery']['ref']} --worktree -- .\ngit -C <new-recovery-folder> read-tree ${event['recovery']['ref']}^2';
  @override
  Component build(BuildContext context) {
    final config = (data['configurations'] as List? ?? [])
        .where((c) => c['repository'] == component.repository)
        .firstOrNull;
    final events = (data['events'] as List? ?? [])
        .where((e) => e['repository'] == component.repository)
        .toList();
    final org =
        connection.selectedOrganization.value ??
        (connection.organizationDirectory.value['organizations'] as List? ?? [])
            .firstOrNull?['id'];
    final enabled = config?['enabled'] == true;
    return card('Integration coordinator', [
      disclosure(
        enabled
            ? '${events.length} tracked decisions · idle-only delivery'
            : 'Coordinate updates without interrupting active work',
        [
          actions([
            badge(
              config == null
                  ? 'Not configured'
                  : enabled
                  ? 'Enabled'
                  : 'Paused',
            ),
            button(
              'Refresh coordination',
              refresh,
              disabled: busy || refreshing,
            ),
          ]),
          paragraph(
            'Last scan: ${displayTime(checked)} · Signed in: ${connection.operator.value['name']} · ${connection.operator.value['role']}',
          ),
          paragraph('Launch details: Org chart → Runs'),
          if (config != null)
            paragraph(
              'Coordinator: ${config['coordinator_state'] ?? 'Checking launch'} ${config['coordinator_error'] ?? ''}',
            ),
          paragraph(
            'The gateway queues exact-commit updates. Enabling coordination lets workers merge after choosing integrate_now; deferred work waits for a checkpoint. Workers can report blockers. The coordinator summarizes supplied Git verification, worker-reported tests and recovery references. Inspect pending permissions in Org chart → Chat. Existing worktrees and sessions stay in place.',
          ),
          if (config?['report_state'] == 'waiting')
            paragraph(
              config?['coordinator_state'] == 'persona_sent'
                  ? 'Fresh summary waiting for collected worker outcomes; the coordinator is ready.'
                  : 'Fresh summary waiting: coordinator is not ready (${config?['coordinator_state'] ?? 'not launched'}). ${config?['coordinator_error'] ?? ''} Inspect its run; delivered once ready.',
            ),
          if (config != null && !enabled)
            paragraph(
              'Coordination is paused. Resume it to request retries; delivered jobs still finish.',
            ),
          if ([
            'uncertain',
            'needs_attention',
          ].contains(config?['report_state'])) ...[
            paragraph(
              'Coordinator report needs attention. ${config?['report_error'] ?? ''} Inspect the conversation in Org chart → Chat. Worker integration continues independently.',
            ),
            actions([
              button(
                'Recover saved report',
                () => repair(config, fresh: false),
                disabled: busy || !enabled,
              ),
              button(
                'Create fresh summary',
                () => repair(config, fresh: true),
                disabled: busy || !enabled,
              ),
            ]),
          ],
          if (!enabled)
            button(
              'Enable coordinator',
              () => action('integration/configure', {
                'repository': component.repository,
                'organization_id': org,
                'profile_id': config?['profile_id'] ?? 'new',
                'enabled': true,
              }),
              primary: true,
              disabled: busy || org == null,
            )
          else
            button(
              'Pause coordination',
              () => action('integration/configure', {
                'repository': component.repository,
                'enabled': false,
              }),
              disabled: busy,
            ),
          if (enabled) ...[
            toggle(
              'Install a missing toolchain automatically',
              config?['auto_sdk'] == true,
              (value) => action('integration/configure', {
                'repository': component.repository,
                'organization_id': config?['organization_id'] ?? org,
                'profile_id': config?['profile_id'],
                'enabled': true,
                'auto_sdk': value,
              }),
              disabled: busy || !admin,
            ),
            paragraph(
              'Queues the pinned toolchain once only when the release declares exactly one. Toolchains are listed in Settings. Only the root service installs it.',
            ),
            toggle(
              'Build incorporated commits automatically',
              config?['auto_build'] == true,
              (value) => action('integration/configure', {
                'repository': component.repository,
                'profile_id': config?['profile_id'],
                'enabled': true,
                'auto_build': value,
              }),
              disabled:
                  busy ||
                  !admin ||
                  (validation['executor'] != 'service' &&
                      config?['auto_build'] != true),
            ),
            paragraph(
              validation['executor'] == 'service'
                  ? 'Queues the exact commit after Git verification; failed builds need explicit retry. Deployment remains an administrator action.'
                  : 'Requires the durable build service. Install as root: bash /opt/herdr-web/install/build-install.sh',
            ),
          ],
          for (final event in events)
            if ('${event['automatic_build_error'] ?? ''}'.isNotEmpty)
              paragraph(
                'Automatic build waiting · ${event['name']}: ${event['automatic_build_error']}',
              ),
          if (validation['error'] != null)
            paragraph('Validation runner unavailable: ${validation['error']}'),
          feedback(),
          if (actionFailure != null) notice(actionFailure, error: true),
          if (events.isEmpty && enabled)
            paragraph(
              'No worker events yet. Job completion and remote fetches wake the watcher; a 60-second background scan remains as fallback.',
            ),
          paragraph(
            'Recovery snapshots include tracked and non-ignored untracked files, plus staging. Ignored files and submodule contents need separate backups. Recover in a separate checkout to preserve current work.',
          ),
          for (final event in (data['recoveries'] as List? ?? events).where(
            (e) =>
                e['repository'] == component.repository &&
                e['recovery'] != null,
          ))
            disclosure(
              'Recovery · ${event['name'] ?? profileName(event['profile_id'])} · ${event['path']} · before integration',
              [
                codeText(
                  'Snapshot: ${event['recovery']['commit']}\nReference: ${event['recovery']['ref']}\nIn this repository use a new empty folder:\n${recoveryCommand(event)}\nOriginal staging tree: ${event['recovery']['ref']}^2\nOriginal HEAD: ${event['recovery']['ref']}^1',
                ),
                button('Copy recovery command', () async {
                  final result = await copyText(
                    recoveryCommand(event),
                    filename: 'recovery-command.txt',
                  );
                  if (mounted) setState(() => message = result);
                }),
              ],
            ),
          disclosure('Audit history', [
            paragraph(
              'Recent 200 audit records. Recovery snapshots remain until explicitly removed.',
            ),
            for (final entry in (data['audit'] as List? ?? []).where(
              (a) => a['repository'] == component.repository,
            ))
              card(
                '${entry['action']}${entry['state'] != null
                    ? ' · ${entry['state']}'
                    : entry['enabled'] == true
                    ? ' · enabled'
                    : entry['enabled'] == false
                    ? ' · paused'
                    : ''}',
                [
                  codeText(
                    '${displayTime(entry['at'])} · ${entry['name'] ?? profileName(entry['profile_id'] ?? 'Gateway')}\n${entry['reason'] ?? ''}',
                  ),
                ],
              ),
          ]),
          if (events.any(
            (e) => [
              'blocked',
              'deferred',
              'validation_pending',
              'validation_failed',
              'validation_waived',
            ].contains(e['state']),
          ))
            button(
              'Review blockers',
              () => reviewBlockers(events, enabled),
              disabled: busy,
            ),
          for (final event in events.take(20))
            card('${event['name']} · ${eventStatus(event)}', [
              codeText(
                '${event['path']} → ${event['target']}\n${event['reason'] ?? ''}${'${event['blocker_label'] ?? ''}'.isEmpty ? '' : '\nBlocker: ${event['blocker_label']}'}${validationRun(event) == null ? '' : '\nExact-commit validation: ${validationRun(event)}'}${'${event['checkpoint'] ?? ''}'.isEmpty ? '' : '\nCheckpoint: ${event['checkpoint']}'}',
              ),
              actions([
                button('Review decision', () => eventDetails(event)),
                if (validationRecord(event) != null &&
                    validationRun(event) != 'running')
                  button(
                    'Download validation log',
                    () => downloadLog(validationRecord(event)!),
                    disabled: busy,
                  ),
                if ([
                  'deferred',
                  'blocked',
                  'validation_pending',
                  'validation_failed',
                ].contains(event['state']))
                  button(
                    eventStatus(event).startsWith('Merged')
                        ? 'Retry validation'
                        : 'Ask again',
                    () => action('integration/retry', {'id': event['id']}),
                    disabled: busy || !enabled,
                  ),
              ]),
            ]),
        ],
      ),
    ]);
  }
}
