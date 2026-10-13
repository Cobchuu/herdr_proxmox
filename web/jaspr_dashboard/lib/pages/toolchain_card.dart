import 'operations_support.dart';

class ToolchainCard extends StatefulComponent {
  const ToolchainCard({super.key});
  @override
  State<ToolchainCard> createState() => _ToolchainState();
}

class _ToolchainState extends OperationsState<ToolchainCard> {
  Map<String, dynamic> sdk = {};
  bool refreshing = false;
  Timer? timer;
  int tick = 0;
  Map<String, dynamic> get toolchains =>
      (sdk['toolchains'] as Map?)?.cast<String, dynamic>() ?? {};
  bool get queued => ['queued', 'running'].contains(sdk['state']);
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (queued || ++tick % 6 == 0) refresh();
    });
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
      final data = await connection.request('sdk');
      if (valid(epoch)) setState(() => sdk = Map<String, dynamic>.from(data));
    } catch (e) {
      if (valid(epoch))
        setState(() => sdk = {'state': 'unavailable', 'error': '$e'});
    } finally {
      if (valid(epoch)) setState(() => refreshing = false);
    }
  }

  Future<void> install(String name) async {
    if (!admin || queued || (toolchains[name]?['required'] ?? '') == '') return;
    await perform((epoch) async {
      await connection.request('sdk/install', {'toolchain': name});
      if (valid(epoch))
        setState(
          () => message =
              '$name installation queued. The root service installs the pinned toolchain.',
        );
    });
    await refresh();
  }

  @override
  Component build(BuildContext context) => card('Development toolchains', [
    paragraph(
      'Versions are pinned by the deployed release. A root service installs the declared toolchain on request.',
    ),
    button('Refresh toolchain status', refresh, disabled: refreshing),
    if (sdk['state'] == 'unavailable')
      paragraph(
        'Toolchain status unavailable: ${sdk['error']}. Verify the updated gateway was restarted.',
      )
    else if (sdk['supported'] != true)
      paragraph(
        'SDK installation service is not configured. Run bash /opt/herdr-web/install/web-install.sh as root inside the LXC, then refresh.',
      )
    else if (sdk['catalog_error'] != null)
      paragraph('Toolchain catalog unavailable: ${sdk['catalog_error']}')
    else if (toolchains.isEmpty)
      paragraph(
        'This release declares no SDK toolchains in install/toolchains.json.',
      )
    else
      for (final entry in toolchains.entries)
        card(
          '${entry.value['label'] ?? entry.key} ${entry.value['required'] ?? ''}',
          [
            badge(
              entry.value['installed'] == true
                  ? 'Executable detected'
                  : entry.key == sdk['toolchain'] && queued
                  ? 'Installation in progress'
                  : 'Absent',
            ),
            paragraph(
              entry.value['installed'] == true
                  ? 'Builds verify the required version.'
                  : (entry.value['required'] ?? '') == ''
                  ? 'This release declares no version. Declare it before installing.'
                  : 'Required ${entry.value['required']}${(entry.value['declared_by'] ?? '') == '' ? '' : ', declared by ${entry.value['declared_by']}'}.',
            ),
            if (entry.value['installed'] != true)
              button(
                'Install ${entry.value['label'] ?? entry.key}',
                () => install(entry.key),
                primary: true,
                disabled:
                    busy ||
                    queued ||
                    !admin ||
                    (entry.value['required'] ?? '') == '',
              ),
          ],
        ),
    if (sdk['error'] != null) paragraph(sdk['error']),
    if (sdk['state'] == 'complete' && '${sdk['output'] ?? ''}'.isNotEmpty)
      disclosure('Installation output', [codeText(sdk['output'])]),
    if (!admin && toolchains.values.any((v) => v['installed'] != true))
      paragraph('Only an administrator can request an SDK installation.'),
    feedback(),
  ]);
}
