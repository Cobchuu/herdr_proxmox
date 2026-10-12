import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:herdr_dashboard/dashboard_bloc.dart';
import 'package:herdr_dashboard/tasks_page.dart';

void main() {
  Future<DashboardBloc> mountTask(WidgetTester tester, List<Map> posts) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = {
      'id': 'task',
      'title': 'Reviewed task',
      'state': 'completed',
      'repository': 'repo',
      'organization_id': 'org',
      'description': 'Criteria',
    };
    final connection = DashboardBloc(
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posts.add({
            'path': request.url.path,
            ...jsonDecode(request.body) as Map,
          });
        }
        final data = request.url.path.endsWith('/tasks')
            ? {
                'tasks': [task],
                'github': {'configured': true},
                'executor': 'service',
              }
            : request.url.path.endsWith('/organizations/directory')
            ? {
                'profiles': [
                  {
                    'id': 'consultant',
                    'name': 'Olaf',
                    'project': '/projects/repo',
                  },
                ],
              }
            : task;
        return http.Response(jsonEncode(data), 200);
      }),
    );
    BlocScope.register<DashboardBloc>(() => connection);
    connection.connect('token');
    connection.operator.value = {'role': 'admin'};
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TasksPage(taskId: 'task')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Automation settings'));
    await tester.tap(find.text('Automation settings'));
    await tester.pumpAndSettle();
    return connection;
  }

  Future<void> finish(WidgetTester tester, DashboardBloc connection) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await connection.disconnect();
    await BlocScope.reset();
  }

  testWidgets(
    'automation rejects invalid and out-of-range limits before submitting',
    (tester) async {
      final posts = <Map>[];
      final connection = await mountTask(tester, posts);
      await tester.ensureVisible(find.text('Edit policy'));
      await tester.tap(find.text('Edit policy'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextFormField, 'Max per meeting');
      for (final invalid in ['abc', '-1', '11', '']) {
        await tester.enterText(field, invalid);
        await tester.tap(find.text('Save policy'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a whole number from 0 to 10.'), findsOneWidget);
        expect(posts, isEmpty);
      }
      await tester.enterText(field, '2');
      await tester.tap(find.text('Save policy'));
      await tester.pumpAndSettle();
      expect(posts.single['path'], '/api/tasks/automation');
      expect(posts.single['max_per_meeting'], 2);
      expect(posts.single.values, isNot(contains(null)));
      await finish(tester, connection);
    },
  );

  testWidgets(
    'consultation submits the selected identity and complete question',
    (tester) async {
      final posts = <Map>[];
      final connection = await mountTask(tester, posts);
      await tester.ensureVisible(find.text('Ask a consultant'));
      await tester.tap(find.text('Ask a consultant'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Question'),
        'Check the merge.\nExplain remaining risks.',
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(posts.single['path'], '/api/tasks/consult');
      expect(posts.single['consultant_profile_id'], 'consultant');
      expect(
        posts.single['question'],
        'Check the merge.\nExplain remaining risks.',
      );
      await finish(tester, connection);
    },
  );

  test(
    'fork status explains authentication limits without raw capability codes',
    () {
      final entry = {
        'publishing_repository': 'contributor/repo',
        'verification': {
          'account_write_to_publishing': 'verified',
          'upstream_pr_creation': 'needs_different_authentication',
        },
      };
      final summary = publicationSummary('owner/repo', entry);
      expect(summary, contains('Different GitHub authentication is required'));
      expect(summary, isNot(contains('needs_different_authentication')));
      expect(
        needsPrAuthentication({
          'publication': {'owner/repo': entry},
        }, 'owner/repo'),
        isTrue,
      );
      expect(needsPrAuthentication({}, 'owner/repo'), isFalse);
    },
  );
}
