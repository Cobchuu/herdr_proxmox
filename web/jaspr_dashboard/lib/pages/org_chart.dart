import 'dart:math' as math;
import 'package:web/web.dart' as web;
import '../ui.dart';
import 'org_forms.dart';

class ChartLayout {
  ChartLayout(List<Json> profiles) {
    final byId = {for (final p in profiles) '${p['id']}': p};
    final visited = <String>{};
    double nextLeaf = 0;
    double place(Json profile, int depth) {
      final id = '${profile['id']}';
      visited.add(id);
      final children = profiles.where(
        (p) => p['manager_id'] == id && !visited.contains(p['id']),
      );
      final xs = <double>[];
      for (final child in children) {
        if (!visited.contains(child['id'])) xs.add(place(child, depth + 1));
      }
      final x = xs.isEmpty ? nextLeaf++ * 250 : (xs.first + xs.last) / 2;
      positions[id] = (x + 30, depth * 160 + 30.0);
      maxDepth = math.max(maxDepth, depth);
      return x;
    }

    for (final p in profiles.where((p) => !byId.containsKey(p['manager_id']))) {
      if (!visited.contains(p['id'])) place(p, 0);
    }
    for (final p in profiles) {
      if (!visited.contains(p['id'])) place(p, 0);
    }
    width = math.max(420, nextLeaf * 250 + 40);
    height = math.max(240, (maxDepth + 1) * 160 + 30);
  }
  final positions = <String, (double, double)>{};
  int maxDepth = 0;
  late double width, height;
}

class OrgChart extends StatefulComponent {
  const OrgChart({
    super.key,
    required this.profiles,
    required this.agents,
    required this.jobs,
    required this.onSelect,
    this.groups = const [],
    this.onSelectGroup,
    this.onConfigure,
  });
  final List<Json> profiles, agents, jobs, groups;
  final void Function(Json) onSelect;
  final void Function(Json)? onSelectGroup, onConfigure;
  @override
  State<OrgChart> createState() => _OrgChartState();
}

class _OrgChartState extends State<OrgChart> {
  double zoom = 1;
  double? dragX, dragY;
  double scrollX = 0, scrollY = 0;
  @override
  Component build(BuildContext context) {
    final layout = ChartLayout(component.profiles);
    return el('section', [
      row([
        button(
          'Zoom out',
          () => setState(() => zoom = math.max(.25, zoom - .15)),
        ),
        badge('${(zoom * 100).round()}%'),
        button('Zoom in', () => setState(() => zoom = math.min(2, zoom + .15))),
        button(
          'Fit chart',
          () => setState(() => zoom = math.min(1, 900 / layout.width)),
        ),
        button('Reset', () => setState(() => zoom = 1)),
      ]),
      el(
        'div',
        [
          el(
            'div',
            [
              el(
                'svg',
                [
                  for (final profile in component.profiles)
                    if (layout.positions.containsKey(profile['manager_id']))
                      el(
                        'path',
                        [],
                        attributes: {
                          'd': _edge(
                            layout.positions['${profile['manager_id']}']!,
                            layout.positions['${profile['id']}']!,
                          ),
                          'fill': 'none',
                          'stroke': 'var(--text-subtle, #6b7b90)',
                          'stroke-width': '2',
                        },
                      ),
                ],
                attributes: {
                  'xmlns': 'http://www.w3.org/2000/svg',
                  'width': '${layout.width}',
                  'height': '${layout.height}',
                  'aria-hidden': 'true',
                  'style': 'position:absolute;inset:0;pointer-events:none;',
                },
              ),
              for (final profile in component.profiles) _node(profile, layout),
            ],
            attributes: {
              'style':
                  'position:relative;width:${layout.width}px;height:${layout.height}px;transform:scale($zoom);transform-origin:top left;',
            },
          ),
        ],
        classes: 'org-chart-viewport',
        attributes: {
          'style':
              'overflow:auto;height:560px;cursor:grab;touch-action:pan-x pan-y;',
          'aria-label': 'Organization chart',
        },
        events: {
          'mousedown': (event) {
            final e = event as web.MouseEvent;
            if (e.target is web.Element &&
                (e.target as web.Element).closest('button') != null)
              return;
            final viewport = e.currentTarget as web.HTMLElement;
            dragX = e.clientX.toDouble();
            dragY = e.clientY.toDouble();
            scrollX = viewport.scrollLeft;
            scrollY = viewport.scrollTop;
          },
          'mousemove': (event) {
            if (dragX == null) return;
            final e = event as web.MouseEvent;
            final viewport = e.currentTarget as web.HTMLElement;
            viewport.scrollLeft = scrollX + dragX! - e.clientX;
            viewport.scrollTop = scrollY + dragY! - e.clientY;
          },
          'mouseup': (_) {
            dragX = null;
            dragY = null;
          },
          'mouseleave': (_) {
            dragX = null;
            dragY = null;
          },
        },
      ),
      if (component.profiles.isEmpty)
        prose('Hire an agent to build your organization.'),
      if (component.groups.isNotEmpty)
        card('Discussion groups', [
          for (final group in component.groups)
            button(
              '${group['name']}',
              () => component.onSelectGroup?.call(group),
            ),
        ]),
    ]);
  }

  String _edge((double, double) parent, (double, double) child) =>
      'M ${parent.$1 + 105} ${parent.$2 + 106} V ${parent.$2 + 130} H ${child.$1 + 105} V ${child.$2}';
  Component _node(Json profile, ChartLayout layout) {
    final pos = layout.positions['${profile['id']}']!;
    final live = component.agents
        .where((a) => a['profile_id'] == profile['id'])
        .firstOrNull;
    return el(
      'article',
      [
        button('${profile['name']}', () => component.onSelect(profile)),
        prose(
          profile['coordination_binding'] == 'used'
              ? 'Used by coordination'
              : profile['coordination_binding'] == 'inactive'
              ? 'Inactive coordinator profile'
              : profile['role'],
        ),
        badge(
          '${live?['agent_status'] ?? live?['state'] ?? 'No live session'}',
        ),
        if (component.onConfigure != null)
          button('Configure', () => component.onConfigure!(profile)),
      ],
      classes: 'card org-chart-node',
      attributes: {
        'style':
            'position:absolute;left:${pos.$1}px;top:${pos.$2}px;width:210px;min-height:106px;padding:12px;',
      },
    );
  }
}
