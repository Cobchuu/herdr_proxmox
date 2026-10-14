@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'package:test/test.dart';
import 'package:jaspr/client.dart';
import 'package:herdr_jaspr_dashboard/pages/org_chart.dart';
import 'package:web/web.dart' as web;

typedef Json = Map<String, dynamic>;
final updates = ValueNotifier<int>(0);

class _Host extends StatefulComponent {
  const _Host(this.child);
  final Component Function() child;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    updates.addListener(changed);
  }

  @override
  void dispose() {
    updates.removeListener(changed);
    super.dispose();
  }

  @override
  Component build(BuildContext context) => component.child();
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));
Iterable<web.Element> elements(String selector) sync* {
  final all = web.document.querySelectorAll('#chart-test $selector');
  for (var i = 0; i < all.length; i++) yield all.item(i) as web.Element;
}

web.HTMLElement get viewport =>
    elements('.org-chart-viewport').single as web.HTMLElement;
web.HTMLElement get scene =>
    elements('.org-chart-scene').single as web.HTMLElement;
double zoom() => double.parse(scene.getAttribute('data-zoom')!);
double offset(String axis) =>
    double.parse(scene.getAttribute('data-offset-$axis')!);
Future<void> click(String label) async {
  (elements('button').firstWhere((b) => b.textContent == label)
          as web.HTMLButtonElement)
      .click();
  await settle();
}

Json profile(String id, {String manager = '', String role = 'Developer'}) => {
  'id': id,
  'name': id,
  'manager_id': manager,
  'role': role,
  'runtime': 'codex',
  'group_id': null,
};
Future<void> loadStyle(String path) async {
  final complete = Completer<void>();
  final link = web.HTMLLinkElement()
    ..rel = 'stylesheet'
    ..href = path;
  link.addEventListener('load', ((web.Event _) => complete.complete()).toJS);
  link.addEventListener(
    'error',
    ((web.Event _) => complete.completeError(
      StateError('Unable to load $path'),
    )).toJS,
  );
  web.document.head!.appendChild(link);
  await complete.future.timeout(const Duration(seconds: 5));
}

void main() {
  late ClientAppBinding binding;
  late web.HTMLDivElement fixture;
  setUpAll(() async {
    await loadStyle('../web/css/tokens.css');
    await loadStyle('../web/styles.css');
    await loadStyle('../web/css/org-chart.css');
    fixture = web.HTMLDivElement()..id = 'chart-test';
    web.document.body!.appendChild(fixture);
    binding = ClientAppBinding();
  });
  setUp(() {
    fixture.style.width = '860px';
    web.document.documentElement!.setAttribute('data-theme', 'light');
  });
  tearDown(() async {
    binding.detachRootComponent();
    fixture.textContent = '';
    await settle();
  });
  Future<void> mount(Component Function() child) async {
    binding.attachRootComponent(_Host(child), attachTo: '#chart-test');
    await settle();
  }

  void expectFitted() {
    final v = viewport.getBoundingClientRect(),
        s = scene.getBoundingClientRect();
    expect(s.width, lessThanOrEqualTo(v.width));
    expect(s.height, lessThanOrEqualTo(v.height));
    expect((s.left - v.left) - (v.width - s.width) / 2, closeTo(0, 2));
    expect((s.top - v.top) - (v.height - s.height) / 2, closeTo(0, 2));
  }

  test(
    'independent saved roots are centred, compact, and have no invented reporting edges',
    () async {
      final roots = [for (var i = 0; i < 6; i++) profile('Agent $i')];
      await mount(
        () => OrgChart(
          profiles: roots,
          agents: const [],
          jobs: const [],
          onSelect: (_) {},
        ),
      );
      expect(elements('.org-chart-node').length, 6);
      expect(elements('svg path'), isEmpty);
      expect(elements('canvas'), isEmpty);
      expectFitted();
      expect(viewport.clientHeight, lessThan(500));
      expect(zoom(), closeTo(1, .01));
      expect(
        elements(
          '.org-chart-node',
        ).cast<web.HTMLElement>().map((n) => n.offsetTop).toSet().length,
        2,
      );
      for (final node in elements('.org-chart-node').cast<web.HTMLElement>()) {
        expect(node.offsetWidth, 232);
        expect(node.offsetHeight, 144);
      }
    },
  );
  test(
    'manager links use fixed card anchors and cycle/orphan input remains safe',
    () async {
      final profiles = [
        profile('Lead', role: 'Team lead'),
        profile('Developer', manager: 'Lead'),
        profile('Reviewer', manager: 'Lead'),
        profile('Orphan', manager: 'missing'),
        profile('Cycle A', manager: 'Cycle B'),
        profile('Cycle B', manager: 'Cycle A'),
      ];
      await mount(
        () => OrgChart(
          profiles: profiles,
          agents: const [],
          jobs: const [],
          onSelect: (_) {},
        ),
      );
      final edges = elements('svg path').toList();
      expect(
        edges.where((e) => e.getAttribute('data-manager-id') == 'Lead').length,
        2,
      );
      expect(
        edges.any((e) => e.getAttribute('data-manager-id') == 'missing'),
        false,
      );
      expect(edges.length, 3);
      for (final edge in edges) {
        final childId = edge.getAttribute('data-profile-id')!;
        final managerId = edge.getAttribute('data-manager-id')!;
        expect(
          profiles.firstWhere((p) => p['id'] == childId)['manager_id'],
          managerId,
        );
      }
      expectFitted();
      expect(elements('.org-chart-node').length, 6);
    },
  );
  test(
    'dragging from an agent name pans and suppresses only the release click',
    () async {
      final selected = <String>[];
      await mount(
        () => OrgChart(
          profiles: [profile('Lead')],
          agents: const [],
          jobs: const [],
          onSelect: (p) => selected.add('${p['id']}'),
        ),
      );
      final name =
          elements('.org-chart-node__name').single as web.HTMLButtonElement;
      final before = offset('x');
      name.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 3,
            button: 0,
            clientX: 100,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            pointerId: 3,
            clientX: 170,
            clientY: 120,
            bubbles: true,
            cancelable: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(
            pointerId: 3,
            clientX: 170,
            clientY: 120,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.MouseEvent(
          'click',
          web.MouseEventInit(detail: 1, bubbles: true, cancelable: true),
        ),
      );
      await settle();
      expect(offset('x'), closeTo(before + 70, .01));
      expect(selected, isEmpty);
      // The next intentional press works immediately; there is no dead-click
      // timeout for users who open a console after positioning the chart.
      name.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 3,
            button: 0,
            clientX: 170,
            clientY: 120,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(
            pointerId: 3,
            clientX: 170,
            clientY: 120,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.MouseEvent(
          'click',
          web.MouseEventInit(detail: 1, bubbles: true, cancelable: true),
        ),
      );
      await settle();
      expect(selected, ['Lead']);
    },
  );
  test(
    'small pointer motion remains a click; group names also pan without navigation',
    () async {
      var opened = 0;
      var selected = 0;
      await mount(
        () => OrgChart(
          profiles: [profile('Lead')],
          agents: const [],
          jobs: const [],
          groups: [
            {
              'id': 'review',
              'name': 'Review',
              'members': ['Lead'],
            },
          ],
          onSelect: (_) => selected++,
          onSelectGroup: (_) => opened++,
        ),
      );
      final name =
          elements('.org-chart-node--agent .org-chart-node__name').single
              as web.HTMLButtonElement;
      final before = offset('x');
      name.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 4,
            button: 0,
            clientX: 100,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            pointerId: 4,
            clientX: 102,
            clientY: 101,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(
            pointerId: 4,
            clientX: 102,
            clientY: 101,
            bubbles: true,
          ),
        ),
      );
      name.dispatchEvent(
        web.MouseEvent('click', web.MouseEventInit(detail: 1, bubbles: true)),
      );
      await settle();
      expect(selected, 1);
      expect(offset('x'), before);
      final group =
          elements('.org-chart-node--group .org-chart-node__name').single
              as web.HTMLButtonElement;
      group.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 5,
            button: 0,
            clientX: 100,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      group.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            pointerId: 5,
            clientX: 160,
            clientY: 100,
            bubbles: true,
            cancelable: true,
          ),
        ),
      );
      group.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(
            pointerId: 5,
            clientX: 160,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      group.dispatchEvent(
        web.MouseEvent('click', web.MouseEventInit(detail: 1, bubbles: true)),
      );
      await settle();
      expect(opened, 0);
      expect(offset('x'), closeTo(before + 60, .01));
      group.click();
      await settle();
      expect(opened, 1);
    },
  );
  test(
    'configuration stays a direct click and cancelled drags do not leave a stuck gesture',
    () async {
      var configured = 0;
      await mount(
        () => OrgChart(
          profiles: [profile('Lead')],
          agents: const [],
          jobs: const [],
          onSelect: (_) {},
          onConfigure: (_) => configured++,
        ),
      );
      final configure =
          elements('.org-chart-node__configure').single
              as web.HTMLButtonElement;
      final before = offset('x');
      configure.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 6,
            button: 0,
            clientX: 100,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      configure.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            pointerId: 6,
            clientX: 150,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      configure.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(
            pointerId: 6,
            clientX: 150,
            clientY: 100,
            bubbles: true,
          ),
        ),
      );
      configure.click();
      await settle();
      expect(configured, 1);
      expect(offset('x'), before);
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 7,
            button: 0,
            clientX: 100,
            clientY: 100,
          ),
        ),
      );
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(
            pointerId: 7,
            clientX: 130,
            clientY: 100,
            cancelable: true,
          ),
        ),
      );
      viewport.dispatchEvent(
        web.PointerEvent('pointercancel', web.PointerEventInit(pointerId: 7)),
      );
      await settle();
      expect(viewport.hasAttribute('data-panning'), false);
      final after = offset('x');
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(pointerId: 7, clientX: 200, clientY: 100),
        ),
      );
      await settle();
      expect(offset('x'), after);
    },
  );
  test(
    'group cards stay inside the chart and console/configuration/group callbacks preserve identity',
    () async {
      String? selected, configured, opened;
      final people = [profile('Lead'), profile('Reviewer', manager: 'Lead')];
      final groups = [
        {
          'id': 'review',
          'name': 'Design review',
          'description': 'Review repository changes and constraints',
          'members': ['Lead', 'Reviewer'],
        },
      ];
      await mount(
        () => OrgChart(
          profiles: people,
          agents: const [],
          jobs: const [],
          groups: groups,
          onSelect: (p) => selected = p['id'],
          onConfigure: (p) => configured = p['id'],
          onSelectGroup: (g) => opened = g['id'],
        ),
      );
      expect(elements('.org-chart-scene .org-chart-node--group').length, 1);
      expect(scene.textContent, contains('Lead, Reviewer'));
      expect(scene.textContent, contains('GROUPS / TOPICS'));
      expectFitted();
      await click('Lead');
      expect(selected, 'Lead');
      final lead = elements(
        '[data-profile-id="Lead"]',
      ).where((n) => n.tagName == 'ARTICLE').single;
      final event = web.MouseEvent(
        'contextmenu',
        web.MouseEventInit(bubbles: true, cancelable: true),
      );
      lead.dispatchEvent(event);
      await settle();
      expect(configured, 'Lead');
      expect(event.defaultPrevented, true);
      await click('# Design review');
      expect(opened, 'review');
    },
  );
  test(
    'wheel zoom anchors to the pointer, drag pans, Fit and resizing re-centre the entire scene',
    () async {
      final roots = [for (var i = 0; i < 5; i++) profile('Agent $i')];
      await mount(
        () => OrgChart(
          profiles: roots,
          agents: const [],
          jobs: const [],
          onSelect: (_) {},
        ),
      );
      final initial = zoom(), oldOffset = offset('x');
      final rect = viewport.getBoundingClientRect();
      final x = rect.width / 3, y = rect.height / 3;
      final oldWorld = (x - oldOffset) / initial;
      final wheel = web.WheelEvent(
        'wheel',
        web.WheelEventInit(
          deltaY: -100,
          clientX: (rect.left + x).round(),
          clientY: (rect.top + y).round(),
          cancelable: true,
        ),
      );
      viewport.dispatchEvent(wheel);
      await settle();
      expect(zoom(), greaterThan(initial));
      expect((x - offset('x')) / zoom(), closeTo(oldWorld, 3));
      expect(wheel.defaultPrevented, true);
      final panBefore = offset('x');
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointerdown',
          web.PointerEventInit(
            pointerId: 1,
            button: 0,
            clientX: 100,
            clientY: 100,
          ),
        ),
      );
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointermove',
          web.PointerEventInit(pointerId: 1, clientX: 160, clientY: 120),
        ),
      );
      viewport.dispatchEvent(
        web.PointerEvent(
          'pointerup',
          web.PointerEventInit(pointerId: 1, clientX: 160, clientY: 120),
        ),
      );
      await settle();
      expect(offset('x'), closeTo(panBefore + 60, .01));
      await click('Fit chart');
      expectFitted();
      fixture.style.width = '360px';
      await settle();
      expectFitted();
      expect(zoom(), lessThan(initial));
    },
  );
  test(
    'saved hierarchy changes auto-fit but live status refresh retains a manually chosen view',
    () async {
      var people = [profile('Lead'), profile('Reviewer', manager: 'Lead')];
      var agents = <Json>[
        {'profile_id': 'Reviewer', 'agent_status': 'blocked'},
      ];
      await mount(
        () => OrgChart(
          profiles: people,
          agents: agents,
          jobs: const [],
          onSelect: (_) {},
        ),
      );
      expect(elements('[data-activity="attention"]').isNotEmpty, true);
      await click('Zoom in');
      final chosenZoom = zoom(), chosenX = offset('x');
      agents = [
        {'profile_id': 'Reviewer', 'agent_status': 'working'},
      ];
      updates.value++;
      await settle();
      expect(zoom(), chosenZoom);
      expect(offset('x'), chosenX);
      expect(elements('[data-activity="working"]').isNotEmpty, true);
      people = [profile('Lead'), profile('Reviewer'), profile('New developer')];
      updates.value++;
      await settle();
      expectFitted();
      expect(elements('svg path'), isEmpty);
    },
  );
  test(
    'historical pane reuse never claims a verified live profile and empty/group-only charts remain usable',
    () async {
      var people = [profile('Lead')];
      var groups = <Json>[];
      await mount(
        () => OrgChart(
          profiles: people,
          agents: [
            {'name': 'old alias', 'pane_id': '%1', 'agent_status': 'working'},
          ],
          jobs: [
            {
              'profile_id': 'Lead',
              'kind': 'launch',
              'state': 'persona_sent',
              'alias': 'old alias',
              'pane_id': '%1',
            },
          ],
          groups: groups,
          onSelect: (_) {},
        ),
      );
      expect(scene.textContent, contains('No live session'));
      expect(scene.textContent, contains('Launch recorded'));
      people = [];
      updates.value++;
      await settle();
      expect(elements('.org-chart__empty').length, 1);
      groups = [
        {
          'id': 'group',
          'name': 'Review',
          'members': [],
          'description': 'A group topic',
        },
      ];
      updates.value++;
      await settle();
      expect(elements('.org-chart-node--group').length, 1);
      expect(elements('.org-chart__empty'), isEmpty);
      expectFitted();
    },
  );
}
