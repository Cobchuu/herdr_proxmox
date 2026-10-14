import 'native_task_ui.dart';
import 'package:jaspr/dom.dart' as dom;
import '../ui.dart' as ui;

/// A native SVG Git graph. Evidence belongs to its exact recorded commit.
class TaskTimeline extends StatelessComponent {
  const TaskTimeline({
    super.key,
    required this.task,
    this.onSelect,
    this.onRefresh,
  });
  final Map task;
  final void Function(String)? onSelect;
  final void Function()? onRefresh;
  static const _row = 88;
  static String shortSha(Map node) {
    final sha = '${node['sha']}';
    return sha.substring(0, sha.length.clamp(0, 8));
  }

  @override
  Component build(BuildContext context) {
    final nodes = [
      for (final node in task['commit_graph'] as List? ?? [])
        if (node is Map) node,
    ];
    if (nodes.isEmpty ||
        !nodes.any((node) => node['sha'] == task['head_sha'])) {
      return ui.el('div', [
        ui.emptyState(
          'Commit history unavailable',
          iconName: 'git-commit-horizontal',
        ),
        ui.el('p', [
          ui.text(
            '${task['history_error'] ?? 'Refresh to load recorded commit history. Viewing history does not capture a new candidate.'}',
          ),
        ], classes: 'task-timeline__note'),
        if (onRefresh != null)
          TextButton(
            onPressed: onRefresh,
            child: const Text('Refresh history'),
          ),
      ], classes: 'task-timeline task-timeline--empty');
    }
    final lanes = <String>[], laneBySha = <String, int>{};
    for (final node in nodes) {
      final sha = '${node['sha']}';
      var lane = lanes.indexOf(sha);
      if (lane < 0) {
        lane = lanes.length;
        lanes.add(sha);
      }
      laneBySha[sha] = lane;
      final parents = (node['parents'] as List? ?? [])
          .map((p) => '$p')
          .toList();
      if (parents.isNotEmpty) lanes[lane] = parents.first;
      for (final parent in parents.skip(1)) {
        if (!lanes.contains(parent)) lanes.add(parent);
      }
    }
    final positions = <String, ({num x, num y})>{};
    final gutter = lanes.length.clamp(1, 6) * 16 + 16;
    for (var i = 0; i < nodes.length; i++) {
      positions['${nodes[i]['sha']}'] = (
        x: 12 + (laneBySha['${nodes[i]['sha']}'] ?? 0).clamp(0, 5) * 16,
        y: i * _row + 20,
      );
    }
    final builds = task['builds'] as Map? ?? {};
    return ui.el('div', [
      ui.el('p', [
        ui.text('Recent commits · newest first'),
      ], classes: 'overline task-timeline__caption'),
      ui.el('div', [
        Component.element(
          tag: 'svg',
          classes: 'task-timeline__graph',
          attributes: {
            'viewBox': '0 0 $gutter ${nodes.length * _row}',
            'width': '$gutter',
            'height': '${nodes.length * _row}',
            'role': 'img',
            'aria-label': 'Recorded Git parent graph',
          },
          children: [
            for (final node in nodes)
              for (final parent in node['parents'] as List? ?? [])
                if (positions['$parent'] != null)
                  Component.element(
                    tag: 'path',
                    classes: 'task-timeline__edge',
                    attributes: {
                      'd':
                          'M ${positions['${node['sha']}']!.x} ${positions['${node['sha']}']!.y} C ${positions['${node['sha']}']!.x} ${(positions['${node['sha']}']!.y + positions['$parent']!.y) / 2} ${positions['$parent']!.x} ${(positions['${node['sha']}']!.y + positions['$parent']!.y) / 2} ${positions['$parent']!.x} ${positions['$parent']!.y}',
                    },
                    children: [],
                  ),
            for (final entry in positions.entries)
              Component.element(
                tag: 'circle',
                classes: 'task-timeline__dot',
                attributes: {
                  'cx': '${entry.value.x}',
                  'cy': '${entry.value.y}',
                  'r': '5',
                  if (entry.key == task['head_sha']) 'data-candidate': '',
                },
                children: [],
              ),
          ],
        ),
        ui.el('ol', [
          for (final node in nodes)
            ui.el('li', [
              if (onSelect != null)
                dom.button(
                  [Component.text('${node['subject'] ?? 'Commit'}')],
                  type: dom.ButtonType.button,
                  classes: 'task-timeline__subject',
                  onClick: () => onSelect!('${node['sha']}'),
                )
              else
                ui.el('span', [
                  ui.text('${node['subject'] ?? 'Commit'}'),
                ], classes: 'task-timeline__subject'),
              dom.span(
                classes: 'task-timeline__meta',
                attributes: {'title': '${node['sha']}'},
                [
                  Component.text(
                    '${node['author'] ?? 'Unknown author'} · ${shortSha(node)}',
                  ),
                ],
              ),
              ui.el('span', [
                if ('${node['refs'] ?? ''}'.isNotEmpty)
                  ui.el('span', [
                    ui.text('${node['refs']}'),
                  ], classes: 'mono-chip'),
                if (node['sha'] == task['base_sha']) ui.badge('Base'),
                if (node['sha'] == task['head_sha'])
                  ui.badge('Candidate', tone: 'accent'),
                if (builds[node['sha']] is Map)
                  builds[node['sha']]['state'] == 'complete' &&
                          builds[node['sha']]['required_checks_verified'] ==
                              true
                      ? ui.badge('Checks verified', tone: 'success')
                      : [
                          'failed',
                          'error',
                        ].contains(builds[node['sha']]['state'])
                      ? ui.badge('Checks failed', tone: 'danger')
                      : ui.badge('Checks not verified', tone: 'warning'),
              ], classes: 'task-timeline__tags'),
            ], classes: 'task-timeline__row'),
        ], classes: 'task-timeline__rows'),
      ], classes: 'task-timeline__body'),
      ui.el('p', [
        ui.text(
          'Only recorded parent edges are shown. Older parents can be outside this bounded history.',
        ),
      ], classes: 'task-timeline__note'),
      if (task['already_upstream'] == true)
        ui.el('p', [
          ui.text(
            'Candidate files match the last fetched base. Deployment is separate.',
          ),
        ], classes: 'task-timeline__note'),
    ], classes: 'task-timeline');
  }
}
