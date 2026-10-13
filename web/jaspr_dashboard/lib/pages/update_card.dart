import 'operations_support.dart';

class UpdateCard extends StatefulComponent {
  const UpdateCard({super.key});
  @override
  State<UpdateCard> createState() => _UpdateState();
}

class _UpdateState extends OperationsState<UpdateCard> {
  Map<String, dynamic>? info;
  List<Map<String, dynamic>> alphas = [];
  String? alphaVersion;
  Timer? timer;
  bool get queued => ['queued', 'running'].contains(info?['state']);
  @override
  void initState() {
    super.initState();
    check();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> check({bool force = false}) => perform((epoch) async {
    final result = await connection.request(
      force ? 'updates/check' : 'updates',
      force ? <String, dynamic>{} : null,
    );
    if (valid(epoch))
      setState(() {
        info = result;
        if (!queued) {
          timer?.cancel();
          timer = null;
        } else {
          timer ??= Timer.periodic(const Duration(seconds: 5), (_) => check());
        }
      });
  });
  Future<void> install({bool alpha = false}) async {
    final version = alpha ? alphaVersion : info?['latest'];
    if (version == null || busy || queued || info?['supported'] != true) return;
    final epoch = connection.generation;
    if (!await confirm(
          'Install $version?',
          '${alpha ? 'This is an experimental feature-branch build for testing. ' : ''}The dashboard briefly disconnects. Your projects, profiles and credentials are preserved. A backup is kept for recovery. Reload after completion.',
          confirmLabel: 'Install update',
        ) ||
        !valid(epoch))
      return;
    await perform((epoch) async {
      await connection.request('updates/install', {
        'version': version,
        if (alpha) 'channel': 'alpha',
        if (alpha) 'confirm_alpha': true,
      });
      if (valid(epoch))
        setState(() {
          info = {...?info, 'state': 'queued'};
          timer ??= Timer.periodic(const Duration(seconds: 5), (_) => check());
        });
    });
  }

  Future<void> loadAlphas() => perform((epoch) async {
    final result = await connection.request(
      'updates/alphas',
      <String, dynamic>{},
    );
    if (valid(epoch))
      setState(() {
        alphas = (result['releases'] as List).cast<Map<String, dynamic>>();
        alphaVersion = null;
        if (alphas.isEmpty)
          error = 'No installable alpha builds are available.';
      });
  });
  @override
  Component build(BuildContext context) => card('Dashboard updates', [
    paragraph(
      'Stable releases from Ultarius/herdr_proxmox. Updates are installed when you choose.',
    ),
    if (info != null) ...[
      paragraph(
        'Installed: ${info!['installed']} · Latest: ${info!['latest'] ?? 'Unavailable'}',
      ),
      badge('${info!['state']}'),
      if (info!['check_diagnostic'] != null)
        paragraph(info!['check_diagnostic'])
      else if (info!['check_error'] != null)
        paragraph('Release lookup unavailable: ${info!['check_error']}'),
      if (info!['check_error'] != null && info!['check_failures'] != null)
        paragraph(
          'Release lookup failed ${info!['check_failures']} times since ${info!['check_failed_since'] ?? 'the first failed check'}. Counts reset when the gateway restarts.',
        ),
      if (info!['state'] == 'complete')
        paragraph(
          info!['check_error'] == null
              ? 'Update complete. Reload to use the new dashboard.'
              : 'The previous installation completed. The current release check failed.',
        ),
      if (info!['error'] != null) paragraph(info!['error']),
      if (info!['deployment_mode'] == 'local')
        paragraph(
          'Release installation is disabled while a local build is deployed.',
        )
      else if (info!['supported'] != true)
        paragraph(
          'Install the updater service before using dashboard updates.',
        ),
      if ('${info!['notes'] ?? ''}'.isNotEmpty) paragraph(info!['notes']),
    ],
    actions([
      button('Check for updates', () => check(force: true), disabled: busy),
      button(
        'Install update',
        install,
        primary: true,
        disabled:
            busy ||
            info?['available'] != true ||
            info?['supported'] != true ||
            queued,
      ),
    ]),
    disclosure('Alpha builds · feature branch testing', [
      button('Browse alpha builds', loadAlphas, disabled: busy),
      if (alphas.isNotEmpty) ...[
        select(
          'Feature branch alpha build',
          alphaVersion ?? '',
          {
            '': 'Select build',
            for (final release in alphas)
              '${release['version']}': '${release['version']}',
          },
          (value) =>
              setState(() => alphaVersion = value.isEmpty ? null : value),
        ),
        if (alphaVersion != null)
          paragraph(
            alphas
                .where((r) => r['version'] == alphaVersion)
                .firstOrNull?['notes'],
          ),
        button(
          'Install selected alpha',
          () => install(alpha: true),
          primary: true,
          disabled:
              busy ||
              alphaVersion == null ||
              info?['supported'] != true ||
              queued,
        ),
      ],
    ]),
    feedback(),
  ]);
}
