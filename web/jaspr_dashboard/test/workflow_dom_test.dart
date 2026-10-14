@TestOn('browser')
library;

import 'dart:convert';
import 'dart:async';
import 'dart:js_interop';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;
import 'package:herdr_jaspr_dashboard/ui.dart';
import 'package:herdr_jaspr_dashboard/pages/task_workflow.dart';

class _Host extends StatefulComponent {
  const _Host(this.ready);
  final void Function(_HostState) ready;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  List<Map<String, dynamic>> tasks = [];
  final opened = <String>[];
  void replace(List<Map<String, dynamic>> rows) => setState(() => tasks = rows);
  @override
  void initState() {
    super.initState();
    component.ready(this);
  }

  @override
  Component build(BuildContext context) => TaskWorkflow(
    tasks: tasks,
    profiles: const [
      {'id': 'worker', 'name': 'Actual worker'},
      {'id': 'reviewer', 'name': 'Independent reviewer'},
    ],
    onOpenTask: opened.add,
    executor: 'service',
    listView: el('div', [
      text('Original task actions preserved'),
      button('Open original task', () => opened.add('original-list')),
    ]),
  );
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 25));
Iterable<web.HTMLElement> nodes(String selector) sync* {
  final list = web.document.querySelectorAll('#workflow-test $selector');
  for (var i = 0; i < list.length; i++) yield list.item(i) as web.HTMLElement;
}

web.HTMLElement task(String id) => nodes('[data-node="$id"]').single;
Future<void> click(String name) async {
  nodes('button').firstWhere((node) => node.textContent == name).click();
  await settle();
}

Future<void> choose(String label, String value) async {
  final control =
      nodes('label')
              .firstWhere(
                (node) => node.querySelector('span')?.textContent == label,
              )
              .querySelector('select')
          as web.HTMLSelectElement;
  control.value = value;
  control.dispatchEvent(web.Event('change', web.EventInit(bubbles: true)));
  await settle();
}

void key(web.HTMLElement element, String value) => element.dispatchEvent(
  web.KeyboardEvent(
    'keydown',
    web.KeyboardEventInit(key: value, bubbles: true, cancelable: true),
  ),
);

Map<String, dynamic> row(
  String id, {
  String state = 'draft',
  String profile = 'worker',
  Map<String, dynamic>? source,
}) => {
  'id': id,
  'title': 'Task $id',
  'state': state,
  'profile_id': profile,
  'repository': 'repo',
  'assigned_agent': {'id': 'template', 'name': 'Template identity'},
  if (source != null) 'source': source,
};

void main() {
  late ClientAppBinding binding;
  late _HostState state;
  setUpAll(() async {
    web.document.body!.appendChild(
      web.HTMLDivElement()
        ..id = 'workflow-test'
        ..style.width = '760px',
    );
    for (final path in [
      '../web/css/tokens.css',
      '../web/css/task-workflow.css',
    ]) {
      final loaded = Completer<void>();
      final link = web.HTMLLinkElement()
        ..rel = 'stylesheet'
        ..href = path;
      link.addEventListener('load', ((web.Event _) => loaded.complete()).toJS);
      link.addEventListener(
        'error',
        ((web.Event _) => loaded.completeError(
          StateError('Cannot load $path'),
        )).toJS,
      );
      web.document.head!.appendChild(link);
      await loaded.future.timeout(const Duration(seconds: 5));
    }
    binding = ClientAppBinding();
  });
  setUp(() async {
    binding.attachRootComponent(
      _Host((value) => state = value),
      attachTo: '#workflow-test',
    );
    await settle();
  });
  tearDown(() {
    binding.detachRootComponent();
    web.document.getElementById('workflow-test')!.textContent = '';
  });

  test(
    'edges are deduplicated recorded follow-ups and execution waits only',
    () async {
      final rows = [
        row('origin')..['follow_up_tasks'] = {'p': 'follow'},
        row('follow', source: {'task_id': 'origin'}),
        row('waiting')..['blocking_execution'] = {'task_id': 'origin'},
        row('same-agent')..['assignment'] = {'state': 'queued', 'position': 2},
        row('unrelated', profile: 'reviewer'),
      ];
      final saved = jsonEncode(rows);
      state.replace(rows);
      await settle();
      expect(nodes('.task-wf-node').length, 5);
      expect(nodes('.task-wf-edge').length, 2);
      expect(nodes('[data-kind=follow-up]').length, 1);
      expect(nodes('[data-kind=execution-wait]').length, 1);
      expect(nodes('.task-wf-edge[data-to=same-agent]'), isEmpty);
      expect(nodes('canvas'), isEmpty);
      expect(
        nodes('.task-wf-legend').single.textContent,
        contains('Recorded follow-up'),
      );
      expect(nodes('#workflow-test').length, 0);
      expect(jsonEncode(rows), saved);
      expect(
        web.document.getElementById('workflow-test')!.textContent,
        isNot(contains('alpha.15')),
      );
    },
  );

  test(
    'selection uses actual worker, template, queue, reviewer and exact commit facts',
    () async {
      final selected = row('parallel')
        ..addAll({
          'assignment': {'state': 'queued', 'position': 4},
          'execution': {
            'mode': 'template',
            'template_id': 'template',
            'template_name': 'Lead engineer',
            'instance_profile_id': 'worker',
          },
          'acceptance': {'reviewer_profile_id': 'reviewer'},
          'run_id': 'recorded-run',
          'head_sha': 'b' * 40,
          'builds': {
            'b' * 40: {
              'target': 'b' * 40,
              'state': 'complete',
              'required_checks_verified': true,
            },
          },
        });
      state.replace([selected]);
      await settle();
      task('parallel').click();
      await settle();
      final inspector = nodes(
        '[aria-label="Selected task details"]',
      ).single.textContent!;
      expect(inspector, contains('Actual worker'));
      expect(inspector, contains('Parallel instance of Lead engineer'));
      expect(inspector, contains('Independent reviewer'));
      expect(inspector, contains('queued · order 4'));
      expect(inspector, contains('recorded-run'));
      expect(
        inspector,
        contains('Required checks verified for this exact commit'),
      );
      expect(state.opened, isEmpty);
      await click('Open task');
      expect(state.opened, ['parallel']);
    },
  );

  test(
    'keyboard follows recorded edges, highlights ancestors and descendants without siblings, Escape clears',
    () async {
      state.replace([
        row('origin'),
        row('left', source: {'task_id': 'origin'}),
        row('right', source: {'task_id': 'origin'}),
        row('leaf', source: {'task_id': 'left'}),
        row('unrelated', profile: 'reviewer'),
      ]);
      await settle();
      task('left').focus();
      task('left').click();
      await settle();
      expect(task('origin').hasAttribute('data-emphasis'), true);
      expect(task('leaf').hasAttribute('data-emphasis'), true);
      expect(task('right').hasAttribute('data-dim'), true);
      key(task('left'), 'ArrowRight');
      await settle();
      expect(task('leaf').getAttribute('aria-pressed'), 'true');
      expect(web.document.activeElement, same(task('leaf')));
      key(task('leaf'), 'ArrowLeft');
      await settle();
      expect(task('left').getAttribute('aria-pressed'), 'true');
      key(task('left'), 'Escape');
      await settle();
      expect(nodes('.task-wf-node[aria-pressed=true]'), isEmpty);
      expect(nodes('[aria-label="Selected task details"]'), isEmpty);
    },
  );

  test(
    'stale complete builds cannot pass exact-commit filters or inspector',
    () async {
      final stale = row('stale', state: 'review_ready')
        ..addAll({
          'head_sha': 'b' * 40,
          'builds': {
            'b' * 40: {
              'target': 'a' * 40,
              'state': 'complete',
              'required_checks_verified': true,
            },
          },
        });
      final verified = row('verified', state: 'review_ready')
        ..addAll({
          'head_sha': 'c' * 40,
          'builds': {
            'c' * 40: {
              'target': 'c' * 40,
              'state': 'complete',
              'required_checks_verified': true,
            },
          },
        });
      state.replace([stale, verified]);
      await settle();
      task('stale').click();
      await settle();
      expect(
        nodes('[aria-label="Selected task details"]').single.textContent,
        contains('No matching current-commit build evidence'),
      );
      await choose('Validation', 'verified');
      expect(nodes('.task-wf-node').length, 1);
      expect(task('verified').textContent, contains('Task verified'));
      await choose('Validation', 'unverified');
      expect(nodes('.task-wf-node').length, 1);
      expect(task('stale').textContent, contains('Task stale'));
      expect(state.opened, isEmpty);
    },
  );

  test(
    'workflow filters and lanes are local; List retains original task actions',
    () async {
      state.replace([
        row('merged', state: 'merged'),
        row('active', state: 'implementing'),
        row('other', profile: 'reviewer')..['repository'] = 'second',
      ]);
      await settle();
      expect(
        nodes('[role=tab][aria-selected=true]').single.textContent,
        'Workflow',
      );
      final hide =
          nodes('label')
                  .firstWhere((node) => node.textContent == 'Hide merged')
                  .querySelector('input')
              as web.HTMLInputElement;
      hide.click();
      await settle();
      expect(nodes('.task-wf-node').length, 2);
      await choose('Repository', 'repo');
      expect(nodes('.task-wf-node').length, 1);
      final lanes =
          nodes('label')
                  .firstWhere((node) => node.textContent == 'Lanes by agent')
                  .querySelector('input')
              as web.HTMLInputElement;
      lanes.click();
      await settle();
      expect(nodes('.task-wf-lane'), isEmpty);
      nodes('[role=tab]').last.click();
      await settle();
      expect(
        nodes('[role=tab][aria-selected=true]').single.textContent,
        contains('List'),
      );
      expect(
        web.document.getElementById('workflow-test')!.textContent,
        contains('Original task actions preserved'),
      );
      expect(state.opened, isEmpty);
      await click('Open original task');
      expect(state.opened, ['original-list']);
      await click('Workflow');
      expect(nodes('.task-wf-node').length, 1);
    },
  );

  test(
    'zoom changes native sizer; Fit uses actual viewport; empty-board drag pans',
    () async {
      final rows = [row('root')];
      for (var i = 0; i < 8; i++) {
        rows.add(
          row(
            'step-$i',
            source: {'task_id': i == 0 ? 'root' : 'step-${i - 1}'},
          ),
        );
      }
      state.replace(rows);
      await settle();
      final sizer = nodes('.task-wf-sizer').single;
      final originalWidth = sizer.getBoundingClientRect().width;
      await click('Zoom in');
      expect(nodes('output').single.textContent, '115%');
      expect(sizer.getBoundingClientRect().width, greaterThan(originalWidth));
      await click('Fit');
      expect(
        int.parse(nodes('output').single.textContent!.replaceAll('%', '')),
        lessThan(100),
      );
      await click('Zoom in');
      await click('Zoom in');
      final area = nodes('.task-wf-viewport').single;
      area.scrollLeft = 0;
      area.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            clientX: 160,
            clientY: 140,
            button: 0,
            pointerId: 1,
            bubbles: true,
          ),
        ),
      );
      area.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            clientX: 60,
            clientY: 140,
            pointerId: 1,
            bubbles: true,
          ),
        ),
      );
      expect(area.scrollLeft, greaterThan(0));
      expect(area.hasAttribute('data-panning'), true);
      area.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(pointerId: 1, bubbles: true),
        ),
      );
      expect(area.hasAttribute('data-panning'), false);
      expect(state.opened, isEmpty);
    },
  );

  test(
    'refresh replaces task data and clears disappeared selection; malformed cycles stay finite',
    () async {
      state.replace([
        row('one', source: {'task_id': 'two'}),
        row('two', source: {'task_id': 'one'}),
      ]);
      await settle();
      expect(nodes('.task-wf-node').length, 2);
      expect(
        nodes('.task-wf-stage').single.getAttribute('style'),
        isNot(contains('Infinity')),
      );
      task('one').click();
      await settle();
      expect(nodes('[aria-label="Selected task details"]').length, 1);
      state.replace([row('new', state: 'completed')]);
      await settle();
      expect(nodes('[aria-label="Selected task details"]'), isEmpty);
      expect(nodes('.task-wf-node').single.getAttribute('data-node'), 'new');
      state.replace([]);
      await settle();
      expect(
        nodes('.task-wf-empty').single.textContent,
        contains('No development tasks yet.'),
      );
      expect(nodes('.task-wf-edge'), isEmpty);
    },
  );
}
