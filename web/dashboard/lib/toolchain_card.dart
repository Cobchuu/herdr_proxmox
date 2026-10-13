import 'package:juice/juice.dart';
import 'dashboard_bloc.dart';

/// Provisionable development toolchains, as declared by the deployed release.
///
/// Each toolchain is named and pinned by `install/toolchains.json`, so this
/// states which one is absent instead of reporting a single yes/no SDK flag.
class ToolchainCard extends StatefulWidget {
  const ToolchainCard({super.key});
  @override
  State<ToolchainCard> createState() => _ToolchainCardState();
}

class _ToolchainCardState extends State<ToolchainCard> {
  // Resolved once: asking the scope for a bloc while building disturbs the
  // surrounding shell's blocs.
  late final DashboardBloc connection;
  Map<String, dynamic> sdk = const {};
  bool busy = false;
  bool refreshing = false;
  String? requestError;
  Timer? timer;
  int pollTick = 0;

  @override
  void initState() {
    super.initState();
    connection = BlocScope.get<DashboardBloc>();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (queued || ++pollTick % 6 == 0) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh({bool showProgress = false}) async {
    if (refreshing || !connection.state.connected) return;
    // Assigned rather than set: initState calls this before the first build,
    // and marking a widget dirty during build is illegal. The completion below
    // still repaints, so the indicator is correct once there is a frame.
    refreshing = true;
    if (showProgress) setState(() {});
    final epoch = connection.generation;
    try {
      final data = await connection.request('sdk');
      if (mounted && epoch == connection.generation)
        setState(() => sdk = Map<String, dynamic>.from(data));
    } catch (error) {
      if (mounted && epoch == connection.generation)
        setState(() => sdk = {'state': 'unavailable', 'error': '$error'});
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> install(String toolchain) async {
    if (busy || !connection.state.connected) return;
    final epoch = connection.generation;
    setState(() {
      busy = true;
      requestError = null;
    });
    try {
      await connection.request('sdk/install', {'toolchain': toolchain});
      if (mounted && epoch == connection.generation)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$toolchain installation queued. The root service installs the pinned toolchain.',
            ),
          ),
        );
    } catch (error) {
      if (mounted && epoch == connection.generation)
        setState(() => requestError = '$error');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await refresh();
      }
    }
  }

  Map<String, dynamic> get toolchains =>
      (sdk['toolchains'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool get queued => sdk['state'] == 'queued' || sdk['state'] == 'running';

  @override
  Widget build(BuildContext context) {
    final role = connection.operator.value['role'];
    final absent = toolchains.values
        .where((toolchain) => toolchain['installed'] != true)
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Development toolchains',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh toolchain status',
                  onPressed: refreshing
                      ? null
                      : () => refresh(showProgress: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Toolchains this release can provision. The versions are pinned by '
              'the release, and a root service installs them on request. This is '
              'separate from the tools an agent installs for one task.',
            ),
            if (sdk['state'] == 'unavailable') ...[
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_outlined),
                title: const Text('Toolchain status unavailable'),
                subtitle: Text(
                  '${sdk['error']}\nVerify that the updated gateway was restarted.',
                ),
              ),
            ] else if (sdk['supported'] != true) ...[
              const SizedBox(height: 12),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.build_outlined),
                title: Text('SDK installation service is not configured'),
                subtitle: Text(
                  'Run bash /opt/herdr-web/install/web-install.sh as root inside the LXC to register the SDK service, then refresh this page.',
                ),
              ),
            ] else if (sdk['catalog_error'] != null) ...[
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_outlined),
                title: const Text('Toolchain catalog unavailable'),
                subtitle: Text('${sdk['catalog_error']}'),
              ),
            ] else if (toolchains.isEmpty) ...[
              const SizedBox(height: 12),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.help_outline),
                title: Text('This release declares no SDK toolchains'),
                subtitle: Text(
                  'The gateway reads install/toolchains.json from the deployed release. A build blocked on a missing toolchain will not resolve until it lists one.',
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              for (final entry in toolchains.entries) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entry.value['installed'] == true
                        ? Icons.check_circle_outline
                        : Icons.build_outlined,
                  ),
                  title: Text(
                    '${entry.value['label'] ?? entry.key}'
                    '${(entry.value['required'] ?? '') == '' ? '' : ' ${entry.value['required']}'}',
                  ),
                  subtitle: entry.value['installed'] == true
                      ? const Text(
                          'Executable detected. Builds verify the required version.',
                        )
                      : Text(
                          entry.key == sdk['toolchain'] && queued
                              ? 'Installation is in progress.'
                              : (entry.value['required'] ?? '') == ''
                              ? 'This release declares no version for it. State the version '
                                    'where the catalog reads it before installing.'
                              : 'Absent. Required ${entry.value['required']}'
                                    '${(entry.value['declared_by'] ?? '') == '' ? '' : ', declared by ${entry.value['declared_by']}'}. '
                                    'A root service installs it on request.',
                        ),
                ),
                if (entry.value['installed'] != true)
                  FilledButton.icon(
                    onPressed:
                        busy ||
                            queued ||
                            role != 'admin' ||
                            (entry.value['required'] ?? '') == ''
                        ? null
                        : () => install(entry.key),
                    icon: const Icon(Icons.download),
                    label: Text(
                      entry.key == sdk['toolchain'] && queued
                          ? 'Installation running'
                          : 'Install ${entry.value['label'] ?? entry.key}',
                    ),
                  ),
              ],
            ],
            if ('${sdk['error'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${sdk['error']}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (requestError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  requestError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (sdk['state'] == 'complete' &&
                '${sdk['output'] ?? ''}'.isNotEmpty)
              ExpansionTile(
                title: const Text('Installation output'),
                children: [SelectableText('${sdk['output']}')],
              ),
            if (absent > 0 && role != 'admin' && sdk['state'] != 'unavailable')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Only an administrator can request an SDK installation.',
                ),
              ),
            if (refreshing) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
