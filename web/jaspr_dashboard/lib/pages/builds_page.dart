import 'dart:convert';
import 'operations_support.dart';
import 'update_card.dart';

class BuildsPage extends StatefulComponent {
  const BuildsPage({super.key});
  @override
  State<BuildsPage> createState() => _BuildsState();
}

class _BuildsState extends OperationsState<BuildsPage> {
  List<Map<String, dynamic>> runs = [];
  Map<String, dynamic>? identity, deployment;
  String executor = 'gateway';
  int queued = 0;
  bool refreshing = false;
  String? downloading;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (refreshing || !connection.state.connected) return;
    refreshing = true;
    final epoch = connection.generation;
    try {
      final validation = await connection.request('validation');
      final deployed = await connection.request('build');
      Map<String, dynamic>? status;
      try {
        status = Map<String, dynamic>.from(await connection.request('updates'));
      } catch (_) {}
      if (valid(epoch))
        setState(() {
          runs = List<Map<String, dynamic>>.from(validation['runs'] ?? []);
          executor = '${validation['executor'] ?? 'gateway'}';
          queued = validation['queued'] as int? ?? 0;
          identity = Map<String, dynamic>.from(deployed);
          deployment = status;
        });
    } catch (e) {
      if (valid(epoch)) setState(() => error = '$e');
    } finally {
      if (valid(epoch)) setState(() => refreshing = false);
    }
  }

  bool get deploying => ['queued', 'running'].contains(deployment?['state']);
  Future<void> promote(Map<String, dynamic> run) async {
    if (!admin ||
        busy ||
        refreshing ||
        deploying ||
        run['deployment_package'] is! Map)
      return;
    final epoch = connection.generation;
    final manifest = run['deployment_package'] as Map;
    final failed = (manifest['checks'] as List? ?? [])
        .where(
          (c) => c is Map && c['required'] != false && c['status'] != 'passed',
        )
        .map((c) => c['id'])
        .join(', ');
    if (!await confirm(
          'Deploy this build?',
          'Source: ${run['target']}\nBuild: ${run['id']}\nPackage hash: ${manifest['sha256']}\n\nYour administrator approval is recorded. Files and configuration are backed up. The gateway restarts and must report this build ID before deployment is complete. Downloading a package never authorizes deployment.\n\nRequired checks not passed: $failed\nEvidence complete: ${manifest['required_checks_verified'] == true}. Review the log; approval never changes an underlying check result.',
          confirmLabel: 'Approve and deploy',
        ) ||
        !valid(epoch))
      return;
    await perform((epoch) async {
      await connection.request('updates/promote', {'run_id': run['id']});
      if (valid(epoch))
        setState(
          () => message =
              'Deployment queued. The gateway restarts when deployment finishes.',
        );
      await refresh();
    });
  }

  Future<void> rollbackDeployment() async {
    if (!admin ||
        busy ||
        deploying ||
        deployment?['rollback_available'] != true)
      return;
    final epoch = connection.generation;
    if (!await confirm(
          'Restore the last deployment?',
          'The current files and configuration are backed up first, then the previous deployment is restored and the gateway restarts. Use this when the running build is unhealthy.',
          confirmLabel: 'Restore previous deployment',
        ) ||
        !valid(epoch))
      return;
    await perform((epoch) async {
      await connection.request('updates/rollback', const {});
      if (valid(epoch)) setState(() => message = 'Rollback queued.');
      await refresh();
    });
  }

  Future<void> repairProvenance() async {
    if (!admin ||
        busy ||
        deploying ||
        deployment?['provenance_repairable'] != true ||
        deployment?['supported'] != true)
      return;
    final epoch = connection.generation;
    if (!await confirm(
          'Resolve release source identity?',
          'The release tag is resolved to its exact commit through the GitHub API and recorded as running build provenance. Only deployment identity metadata is updated; services are not restarted.',
          confirmLabel: 'Resolve source identity',
        ) ||
        !valid(epoch))
      return;
    await perform((epoch) async {
      await connection.request('updates/provenance', const {});
      if (valid(epoch))
        setState(() => message = 'Source identity resolution queued.');
      await refresh();
    });
  }

  Future<void> download(Map<String, dynamic> run, String kind) async {
    if (downloading != null) return;
    final epoch = connection.generation;
    setState(() {
      downloading = '${run['id']}:$kind';
      error = null;
    });
    try {
      if (kind == 'artifact' || kind == 'deployment') {
        final content = await connection.bytes(
          'validation/artifact?id=${run['id']}&kind=${kind == 'deployment' ? 'deployment' : 'static'}',
        );
        final manifest =
            run[kind == 'deployment' ? 'deployment_package' : 'artifact']
                as Map;
        final expected = manifest['bytes'];
        if (expected is! int || expected < 0 || content.length != expected)
          throw Exception(
            'Downloaded size ${content.length} does not match the manifest ($expected bytes).',
          );
        if (!valid(epoch)) return;
        await downloadBytes(content, '$kind-${run['id']}.tar.gz');
        if (valid(epoch))
          setState(
            () => message =
                '$kind package fetched and handed to the browser · ${content.length} bytes verified.',
          );
      } else if (kind == 'manifest') {
        final content = const JsonEncoder.withIndent(
          '  ',
        ).convert(run['artifact']);
        if (!valid(epoch)) return;
        await downloadText(content, 'build-${run['id']}.json');
        if (valid(epoch))
          setState(
            () => message =
                'Manifest fetched · ${utf8.encode(content).length} bytes.',
          );
      } else {
        final content = await connection.text('validation/log?id=${run['id']}');
        if (!valid(epoch)) return;
        await downloadText(content, 'validation-${run['id']}.log');
        if (valid(epoch))
          setState(
            () =>
                message = 'Log fetched · ${utf8.encode(content).length} bytes.',
          );
      }
    } catch (e) {
      if (valid(epoch)) setState(() => error = 'Download failed: $e');
    } finally {
      if (valid(epoch)) setState(() => downloading = null);
    }
  }

  @override
  Component build(BuildContext context) => stack([
    card('Builds & deployments', [
      paragraph('Build executor: $executor · $queued queued'),
      if (executor != 'service')
        paragraph(
          'Durable build service not installed. Builds stop with the gateway; automatic builds stay off. Install as root: bash /opt/herdr-web/install/build-install.sh',
        ),
      paragraph(
        'Build exact integration commits from Git changes. Static artifacts and gateway/UI packages are separate. Downloading never authorizes deployment.',
      ),
      button('Refresh builds', refresh, disabled: refreshing),
      feedback(),
    ]),
    if (identity != null)
      card('Running build', [
        codeText(
          'Build: ${identity!['build_id'] ?? 'Unknown for this installation'}\nSource: ${identity!['source_sha'] ?? 'Unknown'}\nPackage: ${identity!['package_version'] ?? 'Unknown'}\nDeployment mode: ${identity!['deployment_mode'] ?? 'Unknown'}',
        ),
        if (admin &&
            deployment?['provenance_repairable'] == true &&
            deployment?['supported'] == true &&
            !deploying)
          button('Resolve source identity', repairProvenance, disabled: busy),
      ]),
    if (deployment != null)
      card('Deployment', [
        badge('${deployment!['state']}'),
        paragraph('Mode: ${deployment!['deployment_mode'] ?? 'release'}'),
        if (deployment!['build_id'] != null)
          codeText('Deployed build: ${deployment!['build_id']}'),
        if (deployment!['error'] != null) paragraph(deployment!['error']),
        if (admin && deployment!['rollback_available'] == true && !deploying)
          button(
            'Roll back last deployment',
            rollbackDeployment,
            disabled: busy,
          ),
      ]),
    if (runs.isEmpty) paragraph('No validation builds recorded.'),
    for (final run in runs)
      card('${run['repository']} · ${run['state']}', [
        codeText('Source: ${run['target']}\nBuild: ${run['id']}'),
        if (run['task_id'] != null) paragraph('Task/job: ${run['task_id']}'),
        if (run['event_ids'] is List)
          paragraph(
            'Integration events: ${(run['event_ids'] as List).join(', ')}',
          ),
        if (run['validation_waiver'] != null)
          paragraph(
            'The originating event has a validation waiver. Build checks retain their actual results.',
          ),
        paragraph(run['command'] ?? 'Preparing validation'),
        if (run['checks'] is List)
          for (final check in run['checks'])
            if (check is Map)
              paragraph(
                '${check['name'] ?? check['id']} · ${check['status']} · ${check['duration_ms'] ?? 0} ms · exit ${check['exit_code'] ?? 'not run'}\n${check['summary'] ?? ''}',
              ),
        if (run['artifact_error'] != null)
          paragraph(
            'Build output could not be retained: ${run['artifact_error']}',
          ),
        if (run['deployment_package_error'] != null)
          paragraph(
            'Full package unavailable: ${run['deployment_package_error']}',
          ),
        actions([
          button(
            'Download log',
            () => download(run, 'log'),
            disabled: downloading != null,
          ),
          if (run['artifact'] is Map) ...[
            button(
              'Download static artifact',
              () => download(run, 'artifact'),
              disabled: downloading != null,
            ),
            button(
              'Download manifest',
              () => download(run, 'manifest'),
              disabled: downloading != null,
            ),
          ],
          if (run['deployment_package'] is Map) ...[
            button(
              'Download gateway + UI package',
              () => download(run, 'deployment'),
              disabled: downloading != null,
            ),
            if (admin)
              button(
                'Deploy this build',
                () => promote(run),
                primary: true,
                disabled: busy || refreshing || deploying,
              ),
          ],
        ]),
        if (downloading?.startsWith('${run['id']}:') == true)
          paragraph('Downloading…'),
      ]),
    const UpdateCard(),
  ]);
}
