import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:herdr_dashboard/dashboard_bloc.dart';
import 'package:herdr_dashboard/tasks_page.dart';
import 'package:herdr_dashboard/task_activity.dart';

Map<String, dynamic> conflictTask() => {
  'id': 'task',
  'title': 'Existing PR task',
  'description': 'Acceptance criteria and required checks.',
  'state': 'pr_open',
  'repository': 'repo',
  'head_sha': 'b' * 40,
  'base_sha': 'a' * 40,
  'base_ref': 'refs/remotes/origin/main',
  'branch': 'herdr/task-123456abcdef',
  'github_repository': 'owner/repo',
  'publishing_repository': 'contributor/repo',
  'publish': {'head_sha': 'b' * 40},
  'pull': <String, dynamic>{
    'state': 'open',
    'number': 1,
    'mergeable': false,
    'head_sha': 'b' * 40,
  },
  'assigned_agent': {'id': 'nora', 'name': 'Nora', 'runtime': 'opencode'},
  'builds': {
    'b' * 40: {
      'target': 'b' * 40,
      'state': 'complete',
      'required_checks_verified': true,
    },
  },
};

void main() {
  test('conflicts take priority over old successful checks in the header', () {
    final task = conflictTask();
    expect(taskNextStep(task), contains('PR has merge conflicts'));
    task['pull']['mergeable'] = null;
    expect(taskHasPrConflicts(task), isFalse);
    task['pull']['mergeable'] = false;
    task['state'] = 'merged';
    expect(taskNextStep(task), contains('Merged on GitHub'));
    expect(activitySection('pr_repair_started'), 'Activity & agents');
  });

  testWidgets(
    'repair is shown above participation and sends one explicit request',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = conflictTask();
      final posts = <Map<String, dynamic>>[];
      final connection = DashboardBloc(
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.url.path, endsWith('/tasks/repair'));
            posts.add(Map<String, dynamic>.from(jsonDecode(request.body)));
            task['pr_repair'] = {
              'id': 'repair',
              'state': 'queued',
              'message': 'Queued for Nora; other work is not interrupted.',
            };
            return http.Response(
              jsonEncode({
                ...task,
                'action_message': 'A conflict repair is already in progress.',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/tasks')
                  ? {
                      'tasks': [task],
                      'github': {'configured': true},
                    }
                  : task,
            ),
            200,
          );
        }),
      );
      BlocScope.register<DashboardBloc>(() => connection);
      connection.connect('token');
      connection.operator.value = {'role': 'admin'};
      addTearDown(() async {
        await connection.disconnect();
        await BlocScope.reset();
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TasksPage())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open task'));
      await tester.pumpAndSettle();
      expect(find.textContaining('PR has merge conflicts'), findsOneWidget);
      await tester.tap(find.text('Activity & agents'));
      await tester.pumpAndSettle();
      expect(find.text('PR #1 has merge conflicts'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('pr-conflict-repair'))).dy,
        lessThan(tester.getTopLeft(find.text('Agent participation')).dy),
      );
      expect(posts, isEmpty);
      await tester.tap(find.text('Resolve conflicts with Nora'));
      await tester.pumpAndSettle();
      expect(posts, hasLength(1));
      expect(posts.single['task_id'], 'task');
      expect(posts.single['head_sha'], 'b' * 40);
      expect(
        find.text('A conflict repair is already in progress.'),
        findsOneWidget,
      );
      expect(find.text('Resolve conflicts with Nora'), findsNothing);
      expect(find.textContaining('Queued for Nora'), findsWidgets);
      expect(find.text('Cancel queued repair'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await connection.disconnect();
      await BlocScope.reset();
    },
  );

  test('repair progress and validation failure override stale PR status', () {
    final task = conflictTask();
    for (final state in [
      'running',
      'waiting_for_input',
      'monitoring_unavailable',
      'validation_failed',
      'ready',
    ]) {
      task['pr_repair'] = {'state': state, 'message': 'Repair $state'};
      expect(taskNextStep(task), 'Repair $state');
    }
    task['pr_repair'] = {'state': 'published', 'message': 'Repair published'};
    expect(taskNextStep(task), contains('PR has merge conflicts'));
    task['pull']['mergeable'] = null;
    expect(taskNextStep(task), isNot('Repair published'));
  });
}
