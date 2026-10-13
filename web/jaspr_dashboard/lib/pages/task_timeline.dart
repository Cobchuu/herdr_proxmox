import 'native_task_ui.dart';
import 'package:jaspr/dom.dart' as dom;

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
      return Column(
        children: [
          const Text('Commit history unavailable'),
          Text(
            '${task['history_error'] ?? 'Refresh to load recorded commit history. Viewing history does not capture a new candidate.'}',
          ),
          if (onRefresh != null)
            TextButton(
              onPressed: onRefresh,
              child: const Text('Refresh history'),
            ),
        ],
      );
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
        y: i * 124 + 22,
      );
    }
    final builds = task['builds'] as Map? ?? {};
    return Column(
      children: [
        const Text('Recent commits · newest first'),
        Component.element(
          tag: 'div',
          attributes: {
            'style': 'display:flex;align-items:flex-start;min-width:0;',
          },
          children: [
            Component.element(
              tag: 'svg',
              attributes: {
                'viewBox': '0 0 $gutter ${nodes.length * 124}',
                'width': '$gutter',
                'height': '${nodes.length * 124}',
                'style': 'flex-shrink:0;',
                'role': 'img',
                'aria-label': 'Recorded Git parent graph',
              },
              children: [
                for (final node in nodes)
                  for (final parent in node['parents'] as List? ?? [])
                    if (positions['$parent'] != null)
                      Component.element(
                        tag: 'path',
                        attributes: {
                          'd':
                              'M ${positions['${node['sha']}']!.x} ${positions['${node['sha']}']!.y} C ${positions['${node['sha']}']!.x} ${(positions['${node['sha']}']!.y + positions['$parent']!.y) / 2} ${positions['$parent']!.x} ${(positions['${node['sha']}']!.y + positions['$parent']!.y) / 2} ${positions['$parent']!.x} ${positions['$parent']!.y}',
                          'stroke': 'var(--color-accent)',
                          'stroke-width': '2',
                          'fill': 'none',
                        },
                        children: [],
                      ),
                for (final point in positions.values)
                  Component.element(
                    tag: 'circle',
                    attributes: {
                      'cx': '${point.x}',
                      'cy': '${point.y}',
                      'r': '5',
                      'stroke': 'var(--color-accent)',
                      'fill': 'var(--color-surface)',
                    },
                    children: [],
                  ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  for (final node in nodes)
                    Component.element(
                      tag: 'div',
                      attributes: {
                        'style':
                            'height:124px;box-sizing:border-box;overflow:auto;padding:4px;',
                      },
                      children: [
                        if (onSelect != null)
                          TextButton(
                            onPressed: () => onSelect!('${node['sha']}'),
                            child: Text('${node['subject'] ?? 'Commit'}'),
                          )
                        else
                          Text('${node['subject'] ?? 'Commit'}'),
                        dom.span(
                          attributes: {'title': '${node['sha']}'},
                          [
                            Component.text(
                              '${node['author'] ?? 'Unknown author'} · ${shortSha(node)}',
                            ),
                          ],
                        ),
                        if ('${node['refs'] ?? ''}'.isNotEmpty)
                          Text('${node['refs']}'),
                        Wrap(
                          children: [
                            if (node['sha'] == task['base_sha'])
                              const Chip(label: Text('Base')),
                            if (node['sha'] == task['head_sha'])
                              const Chip(label: Text('Candidate')),
                            if (builds[node['sha']] is Map)
                              Text(
                                builds[node['sha']]['state'] == 'complete' &&
                                        builds[node['sha']]['required_checks_verified'] ==
                                            true
                                    ? 'Checks verified'
                                    : [
                                        'failed',
                                        'error',
                                      ].contains(builds[node['sha']]['state'])
                                    ? 'Checks failed'
                                    : 'Checks not verified',
                              ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        const Text(
          'Only recorded parent edges are shown. Older parents can be outside this bounded history.',
        ),
        if (task['already_upstream'] == true)
          const Text(
            'Candidate files match the last fetched base. Deployment is separate.',
          ),
      ],
    );
  }
}
