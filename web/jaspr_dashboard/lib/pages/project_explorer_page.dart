import 'operations_support.dart';
import 'project_git_panel.dart';

class ProjectExplorerPage extends StatefulComponent {
  const ProjectExplorerPage({super.key, this.initialPath = ''});
  final String initialPath;
  @override
  State<ProjectExplorerPage> createState() => _ExplorerState();
}

class _ExplorerState extends OperationsState<ProjectExplorerPage> {
  Map<String, dynamic>? directory, preview;
  String path = '', filter = '';
  bool showHidden = false, gitView = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    gitView = component.initialPath.isNotEmpty;
    open(component.initialPath);
  }

  Future<void> open(String selected) async {
    final epoch = connection.generation, current = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = Map<String, dynamic>.from(
        await connection.request('projects/browse', {'path': selected}),
      );
      if (!valid(epoch) || current != generation) return;
      setState(() {
        if (result['kind'] == 'folder') {
          directory = result;
          path = selected;
          preview = null;
          filter = '';
        } else {
          preview = result;
        }
      });
    } catch (e) {
      if (valid(epoch) && current == generation) setState(() => error = '$e');
    } finally {
      if (valid(epoch) && current == generation) setState(() => busy = false);
    }
  }

  String size(dynamic bytes) {
    if (bytes == null) return '—';
    final n = (bytes as num).toDouble();
    return n < 1024
        ? '${n.toInt()} B'
        : n < 1048576
        ? '${(n / 1024).toStringAsFixed(1)} KB'
        : '${(n / 1048576).toStringAsFixed(1)} MB';
  }

  Future<void> copyPath() async {
    final result = await copyText(
      '${directory?['root']}/${preview!['path']}',
      filename: 'path.txt',
    );
    if (mounted) setState(() => message = result);
  }

  @override
  Component build(BuildContext context) {
    final entries = (directory?['entries'] as List? ?? [])
        .where(
          (e) =>
              (showHidden || !'${e['name']}'.startsWith('.')) &&
              '${e['name']}'.toLowerCase().contains(filter.toLowerCase()),
        )
        .toList();
    final segments = path
        .split('/')
        .where((p) => p.isNotEmpty && p != '.')
        .toList();
    return stack([
      card('Project explorer', [
        paragraph(
          'Browse repositories and worktrees in the container. File previews are read-only.',
        ),
        actions([
          button('Refresh folder', () => open(path), disabled: busy),
          button(
            'Files',
            () => setState(() => gitView = false),
            classes: !gitView ? 'selected' : '',
          ),
          button(
            'Git changes',
            () => setState(() => gitView = true),
            classes: gitView ? 'selected' : '',
          ),
        ]),
        actions([
          button('Projects', () => open(''), disabled: busy),
          for (var i = 0; i < segments.length; i++)
            button(
              segments[i],
              () => open(segments.take(i + 1).join('/')),
              disabled: busy,
            ),
        ]),
        if (directory != null)
          codeText('${directory!['root']}${path.isEmpty ? '' : '/$path'}'),
        field('Filter this folder', filter, (v) => setState(() => filter = v)),
        toggle(
          'Hidden files',
          showHidden,
          (v) => setState(() => showHidden = v),
        ),
        paragraph('${entries.length} items'),
        if (directory?['limited'] == true)
          paragraph(
            'Listing limited to 1,000 items. Open a subfolder to explore further.',
          ),
        feedback(),
      ]),
      if (gitView)
        ProjectGitPanel(
          key: ValueKey(path),
          path: path,
          onOpen: (selected) {
            setState(() => gitView = false);
            open(selected);
          },
        )
      else
        el('div', [
          card('Files', [
            if (entries.isEmpty)
              paragraph(
                filter.isNotEmpty
                    ? 'No entries match your filter.'
                    : (directory?['entries'] as List? ?? []).isNotEmpty
                    ? 'Only hidden entries are present. Enable Hidden files.'
                    : 'This folder is empty.',
              ),
            table(
              ['Name', 'Kind', 'Modified', 'Size'],
              [
                for (final entry in entries)
                  [
                    button(
                      '${entry['name']}',
                      () => open(entry['path'] as String),
                      disabled:
                          busy || !['folder', 'file'].contains(entry['kind']),
                    ),
                    text(entry['kind']),
                    text(displayTime(entry['modified'])),
                    text(size(entry['size'])),
                  ],
              ],
            ),
          ]),
          if (preview != null)
            card('${preview!['path']}', [
              paragraph(size(preview!['size'])),
              actions([
                button('Copy file path', copyPath),
                button('Close preview', () => setState(() => preview = null)),
              ]),
              if (preview!['binary'] == true)
                paragraph('Preview unavailable for binary files.')
              else ...[
                if (preview!['truncated'] == true)
                  paragraph('Showing the first 64 KB.'),
                codeText(preview!['content']),
              ],
            ]),
        ], classes: 'explorer-grid'),
    ]);
  }
}
