@TestOn('browser')
library;

import 'dart:convert';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart' as dom;
import 'package:web/web.dart' as web;
import 'package:herdr_jaspr_dashboard/services.dart';
import 'package:herdr_jaspr_dashboard/ui.dart' as ui;
import 'package:herdr_jaspr_dashboard/pages/tasks_page.dart';
import 'package:herdr_jaspr_dashboard/pages/knowledge_page.dart';
import 'package:herdr_jaspr_dashboard/pages/discovery_panel.dart';

class _Host extends StatefulComponent {
  const _Host(this.child);
  final Component child;
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
    ui.dialogChanges.addListener(changed);
  }

  @override
  void dispose() {
    ui.dialogChanges.removeListener(changed);
    super.dispose();
  }

  @override
  Component build(BuildContext context) =>
      dom.div([component.child, ui.buildDialogs()]);
}

Future<void> settle() async =>
    Future<void>.delayed(const Duration(milliseconds: 30));
Iterable<web.HTMLElement> elements(String selector) sync* {
  final nodes = web.document.querySelectorAll('#task-dom-test $selector');
  for (var i = 0; i < nodes.length; i++) yield nodes.item(i) as web.HTMLElement;
}

web.HTMLButtonElement button(String text) {
  bool matches(web.HTMLElement e) =>
      (e.textContent ?? '')
          .replaceFirst(e.querySelector('.native-icon')?.textContent ?? '', '')
          .trim() ==
      text;
  final inDialog = elements('.dialog-layer:last-child button').where(matches);
  return (inDialog.isNotEmpty
          ? inDialog.first
          : elements('button').where(matches).first)
      as web.HTMLButtonElement;
}

Future<void> click(String text) async {
  button(text).click();
  await settle();
}

web.HTMLElement field(String label) {
  final node = elements('label').firstWhere((e) => e.textContent == label);
  return web.document.getElementById(node.getAttribute('for')!)
      as web.HTMLElement;
}

Future<void> type(String label, String value) async {
  final node = field(label);
  if (node is web.HTMLInputElement) node.value = value;
  if (node is web.HTMLTextAreaElement) node.value = value;
  node.dispatchEvent(web.Event('input', web.EventInit(bubbles: true)));
  await settle();
}

Future<void> choose(String label, String value) async {
  final node = field(label) as web.HTMLSelectElement;
  node.value = value;
  node.dispatchEvent(web.Event('change', web.EventInit(bubbles: true)));
  await settle();
}

void main() {
  late ClientAppBinding binding;
  DashboardBloc? connection;
  final posts = <Map<String, dynamic>>[];
  setUpAll(() {
    Logger.level = Level.off;
    JuiceLoggerConfig.minLevel = Level.off;
    final fixture = web.HTMLDivElement()..id = 'task-dom-test';
    web.document.body!.appendChild(fixture);
    binding = ClientAppBinding();
  });
  setUp(() {
    posts.clear();
  });
  tearDown(() async {
    for (final close in elements(
      '.dialog-layer button',
    ).where((e) => e.textContent == 'Close').toList()) {
      close.click();
    }
    await settle();
    binding.detachRootComponent();
    if (connection != null) {
      await connection!.disconnect();
      connection = null;
    }
    await BlocScope.reset();
    web.document.getElementById('task-dom-test')!.textContent = '';
  });

  Future<void> mount(
    Component page,
    Map<String, dynamic> Function(http.Request) response, {
    bool loseFirst = false,
    String role = 'admin',
  }) async {
    var lost = false;
    connection = DashboardBloc(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posts.add({
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'path': request.url.path,
          });
          if (loseFirst &&
              !lost &&
              request.url.path.startsWith('/api/tasks/')) {
            lost = true;
            return http.Response('{"error":"lost response"}', 503);
          }
        }
        return http.Response(jsonEncode(response(request)), 200);
      }),
    );
    BlocScope.register<DashboardBloc>(() => connection!);
    connection!.connect('token');
    await settle();
    connection!.operator.value = {'role': role};
    binding.attachRootComponent(_Host(page), attachTo: '#task-dom-test');
    await settle();
  }

  Map<String, dynamic> publishedTask() => {
    'id': 'task',
    'title': 'Ready task',
    'state': 'published',
    'repository': 'repo',
    'organization_id': 'org',
    'github_repository': 'owner/repo',
    'head_sha': 'b' * 40,
    'branch': 'herdr/task-branch',
    'base_ref': 'refs/remotes/origin/main',
    'publish': {'head_sha': 'b' * 40},
    'pull_preview': {
      'title': 'Suggested title',
      'body': 'Suggested description',
      'excerpt': 'Finalized group discussion',
      'head_sha': 'b' * 40,
      'repository': 'owner/repo',
      'publishing_repository': 'contributor/repo',
      'head': 'contributor:herdr/task-branch',
      'base': 'main',
    },
  };
  Map<String, dynamic> taskResponse(
    http.Request r,
    Map<String, dynamic> task,
  ) => r.url.path.endsWith('/tasks')
      ? {
          'tasks': [task],
          'github': {'configured': true},
          'executor': 'service',
        }
      : r.url.path.endsWith('/tasks/detail')
      ? task
      : {'workspaces': [], 'agents': []};

  test(
    'missing SDK blockers link to configuration without triggering an installation',
    () async {
      final oldHash = web.window.location.hash;
      addTearDown(
        () => web.window.history.replaceState(
          null,
          '',
          oldHash.isEmpty ? '#' : oldHash,
        ),
      );
      final task = publishedTask()
        ..['error'] = 'Missing required SDK'
        ..['delivery_blocker'] = {'kind': 'missing_toolchain'};
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
      );
      await click('Install the required SDK');
      expect(web.window.location.hash, '#/configuration');
      expect(posts, isEmpty);
    },
  );

  test(
    'PR preview retains public destinations, validation, cancellation and explicit excerpt opt-in',
    () async {
      final task = publishedTask();
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
      );
      await click('Changes');
      await click('Open draft PR');
      expect(
        web.document.getElementById('task-dom-test')!.textContent,
        contains('Open draft PR into: owner/repo'),
      );
      expect(posts, isEmpty);
      await click('Cancel');
      expect(posts, isEmpty);
      await click('Open draft PR');
      await type('PR title', '');
      await type('PR description (Markdown)', '');
      await click('Create draft PR');
      expect(posts, isEmpty);
      expect(
        elements('[role=alert]').map((e) => e.textContent).join(' '),
        contains('Enter a title.'),
      );
      await type('PR title', 'Edited title');
      await type('PR description (Markdown)', 'Edited public description');
      final description =
          field('PR description (Markdown)') as web.HTMLTextAreaElement;
      expect(description.value, isNot(contains('Finalized group discussion')));
      final checkbox =
          elements('input[type=checkbox]').single as web.HTMLInputElement;
      checkbox.click();
      await settle();
      expect(description.value, contains('Finalized group discussion'));
      await click('Create draft PR');
      expect(posts.single['path'], '/api/tasks/pull');
      expect(posts.single['title'], 'Edited title');
      expect(posts.single['body'], contains('Finalized group discussion'));
      expect(posts.single['reviewed'], true);
      expect(posts.single['head_sha'], 'b' * 40);
      expect(posts.single['request_id'], startsWith('task-'));
    },
  );

  test('task action retry keeps the exact durable request identity', () async {
    final task = {
      'id': 'task',
      'title': 'Retry candidate',
      'state': 'implementing',
      'repository': 'repo',
      'run_id': 'run',
    };
    await mount(
      const TasksPage(taskId: 'task'),
      (r) => taskResponse(r, task),
      loseFirst: true,
    );
    await click('Capture candidate');
    expect(posts.length, 1);
    await click('Capture candidate');
    expect(posts.length, 2);
    expect(posts[0]['request_id'], posts[1]['request_id']);
    expect(posts[1]['task_id'], 'task');
  });

  test(
    'publication confirmation binds the fresh reviewed exact commit',
    () async {
      final task = publishedTask()..remove('publish');
      task['state'] = 'review_ready';
      task['diff'] = 'review this exact patch';
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
      );
      await click('Review and publish');
      expect(posts, isEmpty);
      expect(
        web.document.getElementById('task-dom-test')!.textContent,
        contains('review this exact patch'),
      );
      await click('Approve publication');
      expect(posts.single['path'], '/api/tasks/publish');
      expect(posts.single['head_sha'], 'b' * 40);
    },
  );

  test(
    'PR confirmation from a previous connection generation cannot publish',
    () async {
      final task = publishedTask();
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
      );
      await click('Changes');
      await click('Open draft PR');
      connection!.generation++;
      await click('Create draft PR');
      expect(posts, isEmpty);
    },
  );

  test(
    'task creation changes assignee to the selected managed repository',
    () async {
      await mount(
        const TasksPage(),
        (r) => r.url.path.endsWith('/organizations/directory')
            ? {
                'profiles': [
                  {
                    'id': 'maya',
                    'name': 'Maya',
                    'project': '/projects/repo1',
                    'use_worktree': true,
                  },
                  {
                    'id': 'olaf',
                    'name': 'Olaf',
                    'project': '/projects/repo2',
                    'use_worktree': true,
                  },
                ],
              }
            : r.url.path.endsWith('/projects/browse')
            ? {'root': '/projects'}
            : {'tasks': [], 'workspaces': [], 'agents': []},
      );
      await click('Create task');
      posts.clear();
      await type('Task title', 'A repo2 task');
      await type(
        'Change, acceptance criteria and required checks',
        'Keep behavior and verify required checks',
      );
      await choose('Repository', 'repo2');
      expect((field('Assigned agent') as web.HTMLSelectElement).value, 'olaf');
      await click('Create task');
      expect(posts.single['path'], '/api/tasks/create');
      expect(posts.single['repository'], 'repo2');
      expect(posts.single['profile_id'], 'olaf');
      expect(posts.single['base_ref'], '');
    },
  );

  test(
    'task completion requires reviewed evidence and explicit inspection',
    () async {
      final task = publishedTask()..['current_upstream_sha'] = 'a' * 40;
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
      );
      await click('Mark task done');
      expect(button('Confirm completion').disabled, true);
      await type(
        'Reviewed evidence and completion reason',
        'This work is incorporated upstream.',
      );
      expect(button('Confirm completion').disabled, true);
      (elements('input[type=checkbox]').single as web.HTMLInputElement).click();
      await settle();
      expect(button('Confirm completion').disabled, false);
      await click('Confirm completion');
      expect(posts.single['path'], '/api/tasks/complete');
      expect(posts.single['inspected'], true);
      expect(posts.single['head_sha'], 'b' * 40);
      expect(posts.single['upstream_sha'], 'a' * 40);
    },
  );

  test(
    'viewer sees evidence and cannot publish or mutate task policy',
    () async {
      final task = publishedTask();
      await mount(
        const TasksPage(taskId: 'task'),
        (r) => taskResponse(r, task),
        role: 'viewer',
      );
      await click('Changes');
      expect(button('Open draft PR').disabled, true);
      expect(button('Review and publish').disabled, true);
      button('Open draft PR').click();
      await settle();
      expect(posts, isEmpty);
    },
  );

  test('SVG commit graph retains parent edges without a canvas', () async {
    final task = publishedTask();
    task['commit_graph'] = [
      {
        'sha': 'b' * 40,
        'parents': ['a' * 40],
        'subject': 'Candidate',
        'author': 'Maya',
      },
      {'sha': 'a' * 40, 'parents': [], 'subject': 'Base', 'author': 'Maya'},
    ];
    task['base_sha'] = 'a' * 40;
    await mount(const TasksPage(taskId: 'task'), (r) => taskResponse(r, task));
    await click('Changes');
    expect(elements('svg[role=img]').length, 1);
    expect(elements('svg[role=img] path').length, 1);
    expect(elements('svg[role=img] circle').length, 2);
    expect(elements('canvas'), isEmpty);
  });

  test(
    'knowledge create and review require input and retain provenance',
    () async {
      final record = {
        'id': 'knowledge-1',
        'title': 'Reported finding',
        'body': 'Evidence and limitations',
        'kind': 'finding',
        'state': 'reported',
        'repository': 'repo',
        'created_at': '2026-10-13',
        'source': {
          'kind': 'task',
          'task_id': 'task',
          'source_sha': 'a' * 40,
          'checks_verified': false,
        },
        'audit': [],
      };
      await mount(
        const KnowledgePage(organizationId: 'org'),
        (r) => r.url.path.endsWith('/organizations/directory')
            ? {
                'organizations': [
                  {'id': 'org', 'name': 'Team'},
                ],
              }
            : r.url.path.endsWith('/knowledge')
            ? {
                'records': [record],
                'repositories': ['repo'],
                'next_before': null,
              }
            : {'workspaces': [], 'agents': []},
      );
      posts.clear();
      await click('Add knowledge');
      await click('Save knowledge');
      expect(posts, isEmpty);
      await type('Title', 'New finding');
      await type(
        'Finding, evidence and limitations',
        'A scoped reported finding',
      );
      await click('Save knowledge');
      expect(posts.first['mode'], 'create');
      expect(posts.first['organization_id'], 'org');
      expect(posts.first['kind'], 'finding');
      posts.clear();
      await click('Reported findingfinding / reported / repo');
      expect(
        web.document.getElementById('task-dom-test')!.textContent,
        contains('Exact-commit required checks verified: false'),
      );
      await click('Review record');
      await click('Record decision');
      expect(posts, isEmpty);
      await type('Review reason', 'Reviewed current code and limitations');
      await click('Record decision');
      expect(posts.first['mode'], 'review');
      expect(posts.first['id'], 'knowledge-1');
    },
  );

  test(
    'discovery config and run retain organization scope and proposal-only semantics',
    () async {
      final snapshot = <String, dynamic>{
        'organizations': [
          {'id': 'org', 'name': 'Product organization'},
        ],
        'groups': [
          {'id': 'product', 'name': 'Product', 'organization_id': 'org'},
        ],
        'profiles': [
          {'id': 'maya', 'organization_id': 'org', 'project': '/projects/repo'},
        ],
        'projects_root': '/projects',
        'policies': {
          'org': {
            'product_brief': 'Validated tasks',
            'discovery_group_id': 'product',
            'discovery_repository': 'repo',
            'discovery_interval_hours': 168,
            'discovery_max_proposals': 3,
          },
        },
        'meetings': [],
      };
      await mount(
        const DiscoveryPanel(),
        (r) => r.url.path.endsWith('/discovery')
            ? snapshot
            : {'workspaces': [], 'agents': []},
      );
      await click(
        'Product discoveryProduct goals → grounded proposals → approved drafts',
      );
      await click('Configure discovery');
      await type('Product brief', 'Grounded task discovery');
      await click('Save discovery direction');
      expect(posts.single['path'], '/api/tasks/discovery');
      expect(posts.single['organization_id'], 'org');
      expect(posts.single['mode'], 'configure');
      expect(posts.single['discovery_enabled'], false);
      expect(posts.single['discovery_group_id'], 'product');
      expect(posts.single['discovery_repository'], 'repo');
      posts.clear();
      await click('Run discovery now');
      expect(posts.single['mode'], 'run');
      expect(posts.single['organization_id'], 'org');
      expect(posts.single.containsKey('launch'), false);
    },
  );

  test(
    'knowledge supersession requires replacement and a recorded reason',
    () async {
      Map<String, dynamic> record(String id) => {
        'id': id,
        'title': id,
        'body': 'Reported evidence',
        'kind': 'finding',
        'state': 'reported',
        'repository': 'repo',
        'created_at': '2026-10-13',
        'source': {'kind': 'manual'},
        'audit': [],
      };
      await mount(
        const KnowledgePage(organizationId: 'org'),
        (r) => r.url.path.endsWith('/organizations/directory')
            ? {
                'organizations': [
                  {'id': 'org', 'name': 'Team'},
                ],
              }
            : r.url.path.endsWith('/knowledge')
            ? {
                'records': [record('original'), record('replacement')],
                'repositories': ['repo'],
                'next_before': null,
              }
            : {'workspaces': [], 'agents': []},
      );
      posts.clear();
      await click('originalfinding / reported / repo');
      await click('Supersede record');
      await type('Review reason', 'Replaced by newer verified source evidence');
      await click('Record decision');
      expect(posts, isEmpty);
      await choose('Replacement record', 'replacement');
      await click('Record decision');
      expect(posts.first['mode'], 'supersede');
      expect(posts.first['replacement_id'], 'replacement');
      expect(posts.first['id'], 'original');
    },
  );
  test(
    'task index opens the workflow and retains original list navigation',
    () async {
      await mount(
        const TasksPage(),
        (request) => taskResponse(request, publishedTask()),
      );
      final tabs = elements('button[role="tab"]').toList();
      final workflow = tabs.firstWhere(
        (node) => node.textContent!.startsWith('Workflow'),
      );
      final list = tabs.firstWhere(
        (node) => node.textContent!.startsWith('List'),
      );
      expect(workflow.getAttribute('aria-selected'), 'true');
      expect(button('Create task').disabled, false);
      expect(elements('canvas'), isEmpty);
      posts.clear();
      list.click();
      await settle();
      expect(list.getAttribute('aria-selected'), 'true');
      expect(
        elements('h2').any((node) => node.textContent == 'Ready task'),
        true,
      );
      expect(button('Open task').disabled, false);
      workflow.click();
      await settle();
      expect(workflow.getAttribute('aria-selected'), 'true');
      expect(
        posts,
        isEmpty,
        reason: 'Changing presentation never changes task state.',
      );
      list.click();
      await settle();
      await click('Open task');
      expect(web.window.location.hash, '#/tasks/task');
      expect(posts, isEmpty);
    },
  );
}
