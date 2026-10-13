import 'dart:async';
import 'dart:math' as math;
import 'package:jaspr/dom.dart' as dom;
import 'package:web/web.dart' as web;
import '../ui.dart';
import '../navigation.dart' as navigation;
import 'task_activity.dart' show taskAgentName, taskNextStep, shortSha;

const _stateLabels = {
  'draft': 'Draft',
  'implementing': 'Implementing',
  'review_ready': 'Review ready',
  'published': 'Published',
  'pr_open': 'Pull request open',
  'merged': 'Merged',
  'closed': 'Closed',
  'completed': 'Done',
};

/// Phase 2's native workflow board, driven exclusively by recorded task data.
/// Relationships are provenance or execution waits, never inferred prerequisites.
class TaskWorkflow extends StatefulComponent {
  const TaskWorkflow({
    super.key,
    required this.tasks,
    required this.onOpenTask,
    this.listView,
    this.profiles = const [],
    this.executor = 'unavailable',
    this.loading = false,
    this.initialView = 'workflow',
  });
  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> profiles;
  final void Function(String) onOpenTask;
  final Component? listView;
  final String executor, initialView;
  final bool loading;
  @override
  State<TaskWorkflow> createState() => _TaskWorkflowState();
}

class _Link {
  const _Link(this.from, this.to, this.kind);
  final String from, to, kind;
}

class _Box {
  const _Box(this.id, this.agent, this.column, this.x, this.y);
  final String id, agent;
  final int column;
  final double x, y;
  static const width = 232.0, height = 152.0;
}

class _Lane {
  const _Lane(this.agent, this.y, this.height);
  final String agent;
  final double y, height;
}

class _TaskWorkflowState extends State<TaskWorkflow> {
  static int _next = 0;
  late final String instance = 'task-workflow-${_next++}';
  late String view = component.initialView == 'list' ? 'list' : 'workflow';
  String repository = '', status = '', validation = '', agent = '';
  String? selected, hovered;
  bool hideMerged = false, lanes = true, panel = true;
  double zoom = 1;
  ({double x, double y, double left, double top, int id})? drag;
  List<_Box> boxes = [];
  List<_Lane> bands = [];
  List<_Link> links = [];
  double graphWidth = 0, graphHeight = 0;
  web.HTMLElement? get viewport =>
      web.document.getElementById('$instance-viewport') as web.HTMLElement?;

  @override
  void didUpdateComponent(TaskWorkflow old) {
    super.didUpdateComponent(old);
    if (!component.tasks.any((task) => _id(task) == selected)) selected = null;
    if (!component.tasks.any(
      (task) => '${task['repository'] ?? ''}' == repository,
    ))
      repository = '';
    if (!component.tasks.any((task) => _agent(task) == agent)) agent = '';
  }

  String _id(Map task) => '${task['id'] ?? ''}';
  String _agent(Map task) =>
      '${task['profile_id'] ?? (task['assignment'] as Map?)?['profile_id'] ?? (task['assigned_agent'] as Map?)?['id'] ?? ''}';
  String _name(Map task) {
    final owner = component.profiles
        .where((profile) => '${profile['id']}' == _agent(task))
        .firstOrNull;
    return '${owner?['name'] ?? taskAgentName(task, fallback: 'Assignment not recorded')}';
  }

  String _state(Map task) => (task['assignment'] as Map?)?['state'] == 'queued'
      ? 'Queued'
      : _stateLabels['${task['state']}'] ??
            '${task['state'] ?? 'State not recorded'}';
  Map? _evidence(Map task) {
    final target = task['merge_sha'] ?? task['head_sha'];
    final record = (task['builds'] as Map?)?[target];
    return target != null && record is Map && record['target'] == target
        ? record
        : null;
  }

  String _validation(Map task) {
    final evidence = _evidence(task);
    if (evidence?['state'] == 'complete' &&
        evidence?['required_checks_verified'] == true)
      return 'verified';
    if (['queued', 'running'].contains(evidence?['state'])) return 'running';
    return 'unverified';
  }

  String _tone(Map task) {
    if (task['automation_error'] != null ||
        task['assignment_error'] != null ||
        (task['availability'] as Map?)?['state'] == 'decision')
      return 'danger';
    return switch ('${task['state']}') {
      'completed' || 'merged' => 'success',
      'implementing' => 'accent',
      'review_ready' || 'pr_open' => 'warning',
      _ => 'neutral',
    };
  }

  List<Map<String, dynamic>> get shown => component.tasks
      .where(
        (task) =>
            (repository.isEmpty || task['repository'] == repository) &&
            (status.isEmpty || '${task['state']}' == status) &&
            (validation.isEmpty || _validation(task) == validation) &&
            !(hideMerged && task['state'] == 'merged'),
      )
      .toList();

  void _layout(List<Map<String, dynamic>> tasks) {
    final ids = tasks.map(_id).where((id) => id.isNotEmpty).toSet();
    final recorded = <String, _Link>{};
    void add(String from, String to, String kind) {
      if (from == to || !ids.contains(from) || !ids.contains(to)) return;
      recorded['$from:$to:$kind'] = _Link(from, to, kind);
    }

    for (final task in tasks) {
      final source = (task['source'] as Map?)?['task_id'];
      if (source != null) add('$source', _id(task), 'follow-up');
      for (final followUp
          in (task['follow_up_tasks'] as Map? ?? const {}).values) {
        add(_id(task), '$followUp', 'follow-up');
      }
      final blocking = (task['blocking_execution'] as Map?)?['task_id'];
      if (blocking != null) add('$blocking', _id(task), 'execution-wait');
    }
    links = recorded.values.toList();
    final depths = <String, int>{};
    int depth(String id, Set<String> visited) {
      if (depths.containsKey(id)) return depths[id]!;
      if (!visited.add(id)) return 0;
      var result = 0;
      for (final link in links.where((link) => link.to == id)) {
        if (!visited.contains(link.from))
          result = math.max(result, depth(link.from, {...visited}) + 1);
      }
      return depths[id] = result;
    }

    for (final id in ids) {
      depth(id, {});
    }
    final owners = tasks.map(_agent).toSet().toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final task in tasks) {
      final key = '${lanes ? _agent(task) : ''}:${depths[_id(task)] ?? 0}';
      groups.putIfAbsent(key, () => []).add(task);
    }
    final next = <_Box>[], nextBands = <_Lane>[];
    var top = 0.0;
    final maximum = depths.values.fold(0, math.max);
    for (final owner in lanes ? owners : ['']) {
      var tallest = 0.0;
      for (var column = 0; column <= maximum; column++) {
        final list = groups['$owner:$column'] ?? [];
        for (var i = 0; i < list.length; i++) {
          next.add(
            _Box(
              _id(list[i]),
              _agent(list[i]),
              column,
              24 + (lanes ? 168 : 0) + column * 296,
              top + 20 + i * (_Box.height + 16),
            ),
          );
        }
        tallest = math.max(tallest, list.length * (_Box.height + 16));
      }
      final height = math.max(_Box.height + 40, tallest + 24);
      if (lanes) nextBands.add(_Lane(owner, top, height));
      top += height;
    }
    boxes = next;
    bands = nextBands;
    graphWidth = tasks.isEmpty
        ? 0
        : 48 + (lanes ? 168 : 0) + maximum * 296 + _Box.width;
    graphHeight = tasks.isEmpty ? 0 : top + 8;
  }

  Set<String> get emphasis {
    final seed = selected ?? hovered;
    if (seed == null)
      return boxes
          .where((box) => box.agent == agent)
          .map((box) => box.id)
          .toSet();
    Set<String> walk(bool upstream) {
      final found = <String>{seed};
      var changed = true;
      while (changed) {
        changed = false;
        for (final link in links) {
          if (found.contains(upstream ? link.to : link.from) &&
              found.add(upstream ? link.from : link.to))
            changed = true;
        }
      }
      return found;
    }

    return {...walk(true), ...walk(false)};
  }

  void chooseTask(String? id, {bool reveal = false}) {
    setState(() {
      selected = id;
      if (id != null) panel = true;
    });
    if (reveal && id != null) scheduleMicrotask(() => _reveal(id));
  }

  void _reveal(String id) {
    final box = boxes.where((box) => box.id == id).firstOrNull;
    final area = viewport;
    if (box == null || area == null) return;
    area.scrollLeft = math.max(
      0,
      (box.x + _Box.width / 2) * zoom - area.clientWidth / 2,
    );
    area.scrollTop = math.max(
      0,
      (box.y + _Box.height / 2) * zoom - area.clientHeight / 2,
    );
  }

  void setZoom(double value) {
    final area = viewport;
    final centerX =
        ((area?.scrollLeft ?? 0) + (area?.clientWidth ?? 0) / 2) / zoom;
    final centerY =
        ((area?.scrollTop ?? 0) + (area?.clientHeight ?? 0) / 2) / zoom;
    setState(() => zoom = value.clamp(.3, 1.75));
    scheduleMicrotask(() {
      if (!mounted || area == null) return;
      area.scrollLeft = math.max(0, centerX * zoom - area.clientWidth / 2);
      area.scrollTop = math.max(0, centerY * zoom - area.clientHeight / 2);
    });
  }

  void fit() {
    final area = viewport;
    if (area == null || graphWidth == 0 || graphHeight == 0) return;
    setState(
      () => zoom = math
          .min(
            (area.clientWidth - 24) / graphWidth,
            (area.clientHeight - 24) / graphHeight,
          )
          .clamp(.3, 1.25),
    );
    scheduleMicrotask(() {
      if (mounted) {
        area.scrollLeft = 0;
        area.scrollTop = 0;
      }
    });
  }

  void keyFor(String id, web.KeyboardEvent event) {
    String? next;
    if (event.key == 'Escape') {
      event.preventDefault();
      chooseTask(null);
      return;
    }
    if (event.key == 'ArrowRight')
      next = links.where((link) => link.from == id).firstOrNull?.to;
    if (event.key == 'ArrowLeft')
      next = links.where((link) => link.to == id).firstOrNull?.from;
    if (event.key == 'ArrowDown' || event.key == 'ArrowUp') {
      final order = boxes.toList()
        ..sort(
          (a, b) => a.column == b.column
              ? a.y.compareTo(b.y)
              : a.column.compareTo(b.column),
        );
      final index = order.indexWhere((box) => box.id == id);
      final offset = event.key == 'ArrowDown' ? 1 : -1;
      if (index + offset >= 0 && index + offset < order.length)
        next = order[index + offset].id;
    }
    if (next == null) return;
    event.preventDefault();
    chooseTask(next, reveal: true);
    scheduleMicrotask(
      () =>
          (web.document.getElementById('$instance-node-$next')
                  as web.HTMLElement?)
              ?.focus(),
    );
  }

  Component switchControl(
    String label,
    bool value,
    void Function(bool) change,
  ) => el('label', [
    dom.input<bool>(
      type: dom.InputType.checkbox,
      checked: value,
      onChange: change,
    ),
    text(label),
  ], classes: 'task-wf-switch');
  Component node(Map<String, dynamic> task, _Box box, Set<String> highlighted) {
    final id = _id(task),
        assignment = task['assignment'] as Map?,
        execution = task['execution'] as Map?;
    final message = assignment?['state'] == 'queued'
        ? 'Queue order ${assignment?['position'] ?? 'not recorded'}'
        : execution?['mode'] == 'template'
        ? 'Parallel instance of ${execution?['template_name'] ?? 'agent template'}'
        : taskNextStep(task, executor: component.executor);
    return el(
      'button',
      [
        el('span', [
          el('code', [text(shortSha(id))]),
          if (task['pull'] is Map)
            el('span', [
              icon('git-pull-request'),
              text('#${task['pull']['number']}'),
            ], classes: 'task-wf-pr'),
        ], classes: 'task-wf-node-head'),
        el('strong', [
          text(task['title'] ?? 'Untitled task'),
        ], classes: 'task-wf-node-title'),
        el('span', [
          el('span', [text(_name(task))], classes: 'task-wf-node-agent'),
          badge(_state(task), tone: _tone(task)),
        ], classes: 'task-wf-node-foot'),
        el(
          'span',
          [text(message)],
          classes: 'task-wf-node-meta',
          attributes: {'title': message},
        ),
      ],
      classes: 'task-wf-node',
      attributes: {
        'type': 'button',
        'id': '$instance-node-$id',
        'data-node': id,
        'data-state': '${task['state']}',
        'data-tone': _tone(task),
        'aria-pressed': '${selected == id}',
        'aria-label':
            '${task['title']}. ${_state(task)}. ${_name(task)}. $message',
        'title': '$id · ${task['repository'] ?? 'Repository not recorded'}',
        if (highlighted.isNotEmpty && !highlighted.contains(id)) 'data-dim': '',
        if (highlighted.contains(id)) 'data-emphasis': '',
        'style': 'left:${box.x}px;top:${box.y}px;',
      },
      events: {
        'click': (_) => chooseTask(selected == id ? null : id),
        'dblclick': (_) => component.onOpenTask(id),
        'pointerenter': (_) => setState(() => hovered = id),
        'pointerleave': (_) => setState(() => hovered = null),
        'keydown': (event) => keyFor(id, event as web.KeyboardEvent),
      },
    );
  }

  Component graph(List<Map<String, dynamic>> tasks) {
    final highlighted = emphasis;
    return el('section', [
      el(
        'div',
        [
          el(
            'button',
            [icon('users'), text('All agents')],
            classes: 'task-wf-agent',
            attributes: {'type': 'button', 'aria-pressed': '${agent.isEmpty}'},
            events: {'click': (_) => setState(() => agent = '')},
          ),
          for (final owner in tasks.map(_agent).toSet())
            el(
              'button',
              [
                icon('bot'),
                text(_name(tasks.firstWhere((task) => _agent(task) == owner))),
                el('small', [
                  text(
                    '${tasks.where((task) => _agent(task) == owner).length} tasks',
                  ),
                ]),
              ],
              classes: 'task-wf-agent',
              attributes: {
                'type': 'button',
                'aria-pressed': '${agent == owner}',
                'data-agent': owner,
              },
              events: {
                'click': (_) {
                  setState(() {
                    agent = agent == owner ? '' : owner;
                    selected = null;
                  });
                  final first = boxes
                      .where((box) => box.agent == owner)
                      .firstOrNull;
                  if (first != null) scheduleMicrotask(() => _reveal(first.id));
                },
              },
            ),
        ],
        classes: 'task-wf-agents',
        attributes: {
          'role': 'group',
          'aria-label': 'Highlight tasks by assigned agent',
        },
      ),
      el(
        'div',
        [
          if (tasks.isEmpty)
            el('div', [
              icon('workflow'),
              text(
                component.loading
                    ? 'Loading task workflows…'
                    : component.tasks.isEmpty
                    ? 'No development tasks yet.'
                    : 'No tasks match these workflow filters.',
              ),
            ], classes: 'task-wf-empty')
          else
            el(
              'div',
              [
                el(
                  'div',
                  [
                    for (final lane in bands)
                      el(
                        'div',
                        [
                          el('div', [
                            icon('bot'),
                            el('strong', [
                              text(
                                _name(
                                  tasks.firstWhere(
                                    (task) => _agent(task) == lane.agent,
                                  ),
                                ),
                              ),
                            ]),
                            el('small', [
                              text(
                                '${tasks.where((task) => _agent(task) == lane.agent).length} recorded tasks',
                              ),
                            ]),
                          ], classes: 'task-wf-lane-head'),
                        ],
                        classes: 'task-wf-lane',
                        attributes: {
                          'style': 'top:${lane.y}px;height:${lane.height}px;',
                        },
                      ),
                    el(
                      'svg',
                      [for (final link in links) edge(link, highlighted)],
                      classes: 'task-wf-edges',
                      attributes: {
                        'width': '$graphWidth',
                        'height': '$graphHeight',
                        'aria-hidden': 'true',
                        'focusable': 'false',
                      },
                    ),
                    for (final box in boxes)
                      node(
                        tasks.firstWhere((task) => _id(task) == box.id),
                        box,
                        highlighted,
                      ),
                  ],
                  classes: 'task-wf-stage',
                  attributes: {
                    'style':
                        'width:${graphWidth}px;height:${graphHeight}px;transform:scale($zoom);',
                    'role': 'group',
                    'aria-label': 'Recorded task workflow graph',
                  },
                ),
              ],
              classes: 'task-wf-sizer',
              attributes: {
                'style':
                    'width:${graphWidth * zoom}px;height:${graphHeight * zoom}px;',
              },
            ),
        ],
        classes: 'task-wf-viewport',
        attributes: {
          'id': '$instance-viewport',
          'tabindex': '0',
          'aria-label': 'Workflow graph. Drag the empty area to pan.',
          if (drag != null) 'data-panning': '',
        },
        events: {
          'pointerdown': (event) {
            final pointer = event as web.PointerEvent;
            final target = pointer.target as web.Element?;
            if (pointer.button != 0 ||
                target?.closest('button,a') != null ||
                viewport == null)
              return;
            drag = (
              x: pointer.clientX.toDouble(),
              y: pointer.clientY.toDouble(),
              left: viewport!.scrollLeft,
              top: viewport!.scrollTop,
              id: pointer.pointerId,
            );
            viewport!.setAttribute('data-panning', '');
            try {
              viewport!.setPointerCapture(pointer.pointerId);
            } catch (_) {
              /* Synthetic or detached pointer. */
            }
          },
          'pointermove': (event) {
            final pointer = event as web.PointerEvent, pan = drag;
            if (pan == null) return;
            viewport?.scrollLeft = pan.left - (pointer.clientX - pan.x);
            viewport?.scrollTop = pan.top - (pointer.clientY - pan.y);
          },
          'pointerup': (_) {
            drag = null;
            viewport?.removeAttribute('data-panning');
          },
          'pointercancel': (_) {
            drag = null;
            viewport?.removeAttribute('data-panning');
          },
          'keydown': (event) {
            if ((event as web.KeyboardEvent).key == 'Escape') {
              setState(() {
                selected = null;
                agent = '';
              });
            }
          },
        },
      ),
      el('footer', [
        el('span', [
          el('i', [], classes: 'task-wf-edge-key'),
          text('Recorded follow-up'),
        ]),
        el('span', [
          el('i', [], classes: 'task-wf-edge-key task-wf-edge-key-wait'),
          text('Waiting on another task execution'),
        ]),
        text('Only recorded relationships in this task snapshot are shown.'),
      ], classes: 'task-wf-legend'),
    ], classes: 'task-wf-board');
  }

  Component edge(_Link link, Set<String> highlighted) {
    final from = boxes.firstWhere((box) => box.id == link.from),
        to = boxes.firstWhere((box) => box.id == link.to);
    final sx = from.x + _Box.width, sy = from.y + 64, tx = to.x, ty = to.y + 64;
    final skipped = to.column - from.column > 1;
    final channel = graphHeight - 8;
    final path = skipped
        ? 'M$sx $sy H${sx + 24} V$channel H${tx - 24} V$ty H${tx - 7}'
        : tx > sx
        ? 'M$sx $sy C${sx + 32} $sy ${tx - 32} $ty ${tx - 7} $ty'
        : 'M$sx $sy H${sx + 24} V$channel H${tx - 24} V$ty H${tx - 7}';
    final active =
        highlighted.contains(link.from) && highlighted.contains(link.to);
    return el(
      'g',
      [
        el('title', [
          text(
            '${link.from} → ${link.to}: ${link.kind == 'follow-up' ? 'recorded follow-up' : 'waiting on execution'}',
          ),
        ]),
        el('path', [], classes: 'task-wf-edge-line', attributes: {'d': path}),
        el(
          'path',
          [],
          classes: 'task-wf-edge-head',
          attributes: {
            'd': 'M$tx $ty L${tx - 7} ${ty - 4} L${tx - 7} ${ty + 4} Z',
          },
        ),
      ],
      classes: 'task-wf-edge',
      attributes: {
        'data-from': link.from,
        'data-to': link.to,
        'data-kind': link.kind,
        if (active) 'data-emphasis': '',
        if (highlighted.isNotEmpty && !active) 'data-dim': '',
      },
    );
  }

  Component inspector() {
    final task = component.tasks
        .where((task) => _id(task) == selected)
        .firstOrNull;
    if (task == null)
      return el('aside', [
        el('header', [
          icon('workflow'),
          el('h2', [text('Workflow overview')]),
        ]),
        el('p', [
          text(
            'Select a task to inspect its recorded assignment, execution, relationships and exact-commit validation.',
          ),
        ]),
        el('dl', [
          term('Recorded tasks', '${component.tasks.length}'),
          term(
            'Open',
            '${component.tasks.where((task) => !['merged', 'completed', 'closed'].contains(task['state'])).length}',
          ),
          term(
            'Queued assignments',
            '${component.tasks.where((task) => (task['assignment'] as Map?)?['state'] == 'queued').length}',
          ),
          term('Visible relationships', '${links.length}'),
        ]),
        el('p', [
          text(
            'Follow-up links show provenance. Execution-wait links show recorded occupancy; they do not define a code dependency.',
          ),
        ], classes: 'muted'),
      ], classes: 'task-wf-inspector card');
    final execution = task['execution'] as Map?,
        assignment = task['assignment'] as Map?,
        target = task['merge_sha'] ?? task['head_sha'],
        build = _evidence(task);
    final reviewer = (task['acceptance'] as Map?)?['reviewer_profile_id'];
    final reviewerName =
        component.profiles
            .where((profile) => profile['id'] == reviewer)
            .firstOrNull?['name'] ??
        reviewer;
    final related = links
        .where((link) => link.from == selected || link.to == selected)
        .toList();
    return el(
      'aside',
      [
        el('header', [
          icon('list-checks'),
          el('h2', [text(task['title'] ?? 'Untitled task')]),
          button('Clear selection', () => chooseTask(null)),
        ]),
        el('code', [text(_id(task))]),
        badge(_state(task), tone: _tone(task)),
        el('p', [text(taskNextStep(task, executor: component.executor))]),
        el('h3', [text('Assignment & execution')]),
        el('dl', [
          term('Assigned agent', _name(task)),
          term('Profile', _agent(task).isEmpty ? 'Not recorded' : _agent(task)),
          term('Repository', task['repository'] ?? 'Not recorded'),
          if (assignment != null)
            term(
              'Assignment',
              '${assignment['state']} · order ${assignment['position'] ?? 'not recorded'}',
            ),
          if (execution != null)
            term(
              'Execution',
              execution['mode'] == 'template'
                  ? 'Parallel instance of ${execution['template_name'] ?? execution['template_id']}'
                  : execution['mode'] ?? 'Recorded',
            ),
          if (task['run_id'] != null) term('Run', task['run_id']),
          if (reviewer != null) term('Acceptance reviewer', reviewerName),
          if (task['updated_at'] != null) term('Updated', task['updated_at']),
        ]),
        el('h3', [text('Recorded relationships')]),
        if (related.isEmpty)
          el('p', [
            text('No relationships to other visible tasks are recorded.'),
          ]),
        for (final link in related)
          el('div', [
            text(
              link.kind == 'follow-up'
                  ? (link.to == selected
                        ? 'Follow-up of'
                        : 'Proposed follow-up')
                  : (link.to == selected
                        ? 'Waiting on execution of'
                        : 'Execution blocking'),
            ),
            button(
              '${component.tasks.firstWhere((candidate) => _id(candidate) == (link.to == selected ? link.from : link.to))['title']}',
              () => chooseTask(
                link.to == selected ? link.from : link.to,
                reveal: true,
              ),
            ),
          ], classes: 'task-wf-relationship'),
        if ((task['source'] as Map?)?['task_id'] != null &&
            !component.tasks.any(
              (candidate) => _id(candidate) == '${task['source']['task_id']}',
            ))
          button(
            'Open originating task outside this snapshot',
            () => component.onOpenTask('${task['source']['task_id']}'),
          ),
        el('h3', [text('Validation & publication')]),
        el('dl', [
          term('Candidate', target ?? 'Not captured'),
          term(
            'Validation',
            _validation(task) == 'verified'
                ? 'Required checks verified for this exact commit'
                : build != null
                ? '${build['state']} · required checks not verified'
                : 'No matching current-commit build evidence',
          ),
          term('Branch', task['branch'] ?? 'Not recorded'),
          if (task['pull'] is Map)
            term(
              'Pull request',
              '#${task['pull']['number']} · ${task['pull']['draft'] == true ? 'Draft' : task['pull']['state']}',
            ),
        ]),
        el('p', [
          text(
            'Validation, publication, merge and deployment are separate recorded operations.',
          ),
        ], classes: 'muted'),
        el('div', [
          button(
            'Open task',
            () => component.onOpenTask(_id(task)),
            primary: true,
          ),
          if (_agent(task).isNotEmpty)
            button(
              'Open assigned agent',
              () => navigation.navigate(
                '/agents/${Uri.encodeComponent(_agent(task))}',
              ),
            ),
          button('Builds & deployments', () => navigation.navigate('/builds')),
        ], classes: 'actions'),
      ],
      classes: 'task-wf-inspector card',
      attributes: {'aria-label': 'Selected task details'},
    );
  }

  Component term(String label, Object? value) => el('div', [
    el('dt', [text(label)]),
    el('dd', [text(value)]),
  ]);

  @override
  Component build(BuildContext context) {
    final tasks = shown;
    _layout(tasks);
    final repositories =
        component.tasks
            .map((task) => '${task['repository'] ?? ''}')
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return el('section', [
      el(
        'div',
        [
          for (final value in ['workflow', 'list'])
            el(
              'button',
              [
                icon(value == 'workflow' ? 'workflow' : 'list'),
                text(value == 'workflow' ? 'Workflow' : 'List'),
                if (value == 'list')
                  el('span', [text(component.tasks.length)], classes: 'count'),
              ],
              classes: 'task-wf-tab',
              attributes: {
                'type': 'button',
                'role': 'tab',
                'id': '$instance-tab-$value',
                'aria-selected': '${view == value}',
                'aria-controls': '$instance-panel-$value',
              },
              events: {'click': (_) => setState(() => view = value)},
            ),
        ],
        classes: 'task-wf-tabs',
        attributes: {'role': 'tablist', 'aria-label': 'Task view'},
      ),
      if (view == 'workflow')
        el('div', [
          select('Repository', repository, {
            '': 'All repositories',
            for (final name in repositories) name: name,
          }, (value) => setState(() => repository = value)),
          select('Task state', status, {
            '': 'All states',
            for (final state
                in component.tasks.map((task) => '${task['state']}').toSet())
              state: _stateLabels[state] ?? state,
          }, (value) => setState(() => status = value)),
          select('Validation', validation, {
            '': 'All evidence',
            'verified': 'Exact commit verified',
            'running': 'Queued or running',
            'unverified': 'Not verified',
          }, (value) => setState(() => validation = value)),
          switchControl(
            'Hide merged',
            hideMerged,
            (value) => setState(() => hideMerged = value),
          ),
          switchControl(
            'Lanes by agent',
            lanes,
            (value) => setState(() => lanes = value),
          ),
          el(
            'span',
            [
              text(
                'Showing ${tasks.length} of ${component.tasks.length} tasks',
              ),
            ],
            classes: 'task-wf-result',
            attributes: {'aria-live': 'polite'},
          ),
          el(
            'div',
            [
              button(
                'Zoom out',
                () => setZoom(zoom - .15),
                disabled: zoom <= .3,
              ),
              el(
                'output',
                [text('${(zoom * 100).round()}%')],
                attributes: {
                  'aria-label': 'Workflow zoom',
                  'aria-live': 'polite',
                },
              ),
              button(
                'Zoom in',
                () => setZoom(zoom + .15),
                disabled: zoom >= 1.75,
              ),
              button('Fit', fit),
            ],
            classes: 'task-wf-zoom',
            attributes: {'role': 'group', 'aria-label': 'Workflow zoom'},
          ),
          el(
            'button',
            [
              icon('panel-right'),
              text(panel ? 'Hide details' : 'Show details'),
            ],
            classes: 'btn btn--secondary',
            attributes: {
              'type': 'button',
              'aria-expanded': '$panel',
              'aria-controls': '$instance-inspector',
            },
            events: {'click': (_) => setState(() => panel = !panel)},
          ),
        ], classes: 'task-wf-toolbar'),
      el(
        'div',
        [
          el(
            'div',
            [
              if (view == 'workflow')
                graph(tasks)
              else
                component.listView ??
                    table(
                      ['Task', 'Agent', 'State', 'Repository'],
                      [
                        for (final task in component.tasks)
                          [
                            button(
                              '${task['title']}',
                              () => component.onOpenTask(_id(task)),
                            ),
                            text(_name(task)),
                            badge(_state(task), tone: _tone(task)),
                            text(task['repository']),
                          ],
                      ],
                    ),
            ],
            classes: 'task-wf-main',
            attributes: {
              'role': 'tabpanel',
              'id': '$instance-panel-$view',
              'aria-labelledby': '$instance-tab-$view',
            },
          ),
          if (view == 'workflow' && panel)
            el('div', [inspector()], attributes: {'id': '$instance-inspector'}),
        ],
        classes: 'task-wf-layout',
        attributes: {'data-panel': '$panel', 'data-view': view},
      ),
    ], classes: 'task-workflow');
  }
}
