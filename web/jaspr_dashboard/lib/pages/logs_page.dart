import 'package:web/web.dart' as web;
import 'operations_support.dart';

String logSize(int bytes) =>
    '${(bytes / 1000000).toStringAsFixed(bytes < 10000 ? 6 : 3)} MB';

class LogsPage extends StatefulComponent {
  const LogsPage({super.key});
  @override
  State<LogsPage> createState() => _LogsState();
}

class _LogsState extends OperationsState<LogsPage> {
  String pane = '', label = '', source = 'visible';
  List<Map<String, dynamic>> logs = [];
  String? preview;
  int total = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final epoch = connection.generation;
    if (!connection.state.connected) return;
    try {
      final result = await connection.request('logs');
      if (valid(epoch))
        setState(() {
          logs = List<Map<String, dynamic>>.from(result['logs']);
          total = result['total_bytes'] as int;
        });
    } catch (e) {
      if (valid(epoch)) setState(() => error = '$e');
    }
  }

  Future<void> action(String name, Map<String, dynamic> body) => perform((
    epoch,
  ) async {
    final result = await connection.request('logs/$name', body);
    if (!valid(epoch)) return;
    if (name == 'preview')
      setState(
        () => preview =
            '${result['truncated'] == true ? '[Last 8 KB of saved text]\n' : ''}${result['text']}',
      );
    else {
      setState(() => preview = null);
      await refresh();
    }
  });
  Future<void> open(Map<String, dynamic> log, String mode) async {
    // Reserve synchronously while the browser still grants user activation.
    final window = web.window.open('about:blank', '_blank');
    final epoch = connection.generation;
    try {
      if (window == null)
        throw Exception('Allow pop-ups to open the text log.');
      window.opener = null;
      window.document.body?.textContent = 'Opening saved terminal text…';
      final data = await connection.request('logs/ticket', {
        'id': log['id'],
        'mode': mode,
      });
      if (!valid(epoch)) {
        window.close();
        return;
      }
      window.location.replace(
        Uri.base
            .resolve('/logs/view#${data['mode']}:${data['ticket']}')
            .toString(),
      );
    } catch (e) {
      window?.close();
      if (valid(epoch)) setState(() => error = '$e');
    }
  }

  Future<void> delete(Map<String, dynamic> log) async {
    final epoch = connection.generation;
    if (await confirm(
          'Delete saved snapshot?',
          '${log['label']} (${logSize(log['size_bytes'] as int)})',
          confirmLabel: 'Delete',
        ) &&
        valid(epoch))
      await action('delete', {'id': log['id']});
  }

  @override
  Component build(BuildContext context) => stack([
    card('Saved terminal logs', [
      paragraph(
        'Save retained terminal text before closing a pane. These are snapshots, not guaranteed full run transcripts. Setup/login terminals are never archived here.',
      ),
      paragraph(
        'Stored: ${logSize(total)} / 100 MB. 1 MB = 1,000,000 bytes. Download limit: 10 MB.',
      ),
      button('Refresh logs', refresh, disabled: busy),
      field('Pane ID, e.g. w1:p1', pane, (v) => pane = v),
      actions([
        for (final agent in connection.state.agents)
          button(
            '${agent['name'] ?? agent['pane_id']}',
            () => setState(() {
              pane = '${agent['pane_id']}';
              label = '${agent['name'] ?? agent['pane_id']}';
            }),
          ),
      ]),
      field('Snapshot label (optional)', label, (v) => label = v),
      select(
        'Source',
        source,
        {
          'visible': 'Visible screen — passive read',
          'recent-unwrapped': 'Recent history (idle agent)',
        },
        (v) {
          if (!busy) setState(() => source = v);
        },
      ),
      paragraph(
        'Recent history exports up to 2,000 terminal rows. Older output may no longer be available.',
      ),
      button(
        'Save text snapshot',
        () => action('save', {
          'pane': pane.trim(),
          'label': label.trim().isEmpty ? pane.trim() : label.trim(),
          'source': source,
        }),
        primary: true,
        disabled: busy,
      ),
      feedback(),
    ]),
    for (final log in logs)
      card('${log['label']} — ${logSize(log['size_bytes'] as int)}', [
        paragraph(
          '${log['size_bytes']} bytes · ${log['pane']} · ${log['source']} · ${log['created_at']}',
        ),
        actions([
          button(
            'Preview last 8 KB',
            () => action('preview', {'id': log['id']}),
            disabled: busy,
          ),
          button('Open text page', () => open(log, 'view')),
          button(
            'Download .txt',
            () => open(log, 'download'),
            disabled: log['download_allowed'] != true,
          ),
          button('Delete snapshot', () => delete(log), disabled: busy),
        ]),
      ]),
    if (preview != null)
      card('Snapshot preview', [
        codeText(preview),
        button('Close preview', () => setState(() => preview = null)),
      ]),
  ]);
}
