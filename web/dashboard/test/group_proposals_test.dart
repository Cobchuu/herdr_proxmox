import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:herdr_dashboard/dashboard_bloc.dart';
import 'package:herdr_dashboard/group_page.dart';
import 'package:herdr_dashboard/routes.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'group proposals show the cap reason and inherited limits at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = {
          'groups': [
            {
              'id': 'group',
              'organization_id': 'org',
              'name': 'Refactoring Council',
              'description': 'Review architecture',
              'members': ['nora', 'felix'],
            },
          ],
          'profiles': [
            {'id': 'nora', 'organization_id': 'org', 'name': 'Nora'},
          ],
          'jobs': [
            {
              'id': 'discussion',
              'kind': 'discussion',
              'group_id': 'group',
              'organization_id': 'org',
              'state': 'artifact_ready',
              'created_at': '2026-10-12',
              'result': 'Review complete',
              'group': {'description': 'Review'},
              'contributions': [],
              'proposal_details': [
                {
                  'key': 'first',
                  'title': 'Harden coverage',
                  'description': 'Acceptance criteria',
                  'profile_id': 'nora',
                  'status': 'draft',
                  'task_id': 'created',
                  'needs_review': true,
                },
                {
                  'key': 'second',
                  'title': 'Fix flaky ordering',
                  'description': 'Run repeat checks',
                  'profile_id': 'nora',
                  'status': 'skipped',
                  'reason': 'meeting limit reached',
                  'needs_review': true,
                },
              ],
            },
          ],
        };
        final reads = <String>[];
        final posts = <String>[];
        final connection = DashboardBloc(
          client: MockClient((request) async {
            reads.add(request.url.path);
            if (request.method == 'POST' &&
                !request.url.path.endsWith('/history'))
              posts.add(request.url.path);
            return http.Response(
              jsonEncode(
                request.url.path.endsWith('/automation')
                    ? {
                        'organization_id': 'org',
                        'policy': {'max_per_meeting': 1},
                      }
                    : request.url.path.endsWith('/history')
                    ? data
                    : {'workspaces': [], 'agents': []},
              ),
              200,
            );
          }),
        );
        BlocScope.register<DashboardBloc>(() => connection);
        connection.connect('token');
        connection.operator.value = {
          'role': width == 390 ? 'admin' : 'operator',
        };
        final coordinator = AppCoordinator();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GroupPage(id: 'group', coordinator: coordinator),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Proposals'));
        await tester.tap(find.text('Proposals'));
        await tester.pumpAndSettle();
        expect(find.text('Harden coverage'), findsOneWidget);
        expect(find.text('Fix flaky ordering'), findsOneWidget);
        expect(find.text('Draft created'), findsOneWidget);
        expect(find.text('Skipped'), findsOneWidget);
        expect(find.text('meeting limit reached'), findsOneWidget);
        expect(find.text('Open created task'), findsOneWidget);
        await tester.ensureVisible(
          find.text('View group and organization limits'),
        );
        await tester.tap(find.text('View group and organization limits'));
        await tester.pumpAndSettle();
        expect(reads, contains('/api/organizations/automation'));
        expect(find.textContaining('Max per meeting: 1'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Edit policy'),
              )
              .onPressed,
          width == 390 ? isNotNull : isNull,
        );
        expect(posts, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await connection.disconnect();
        coordinator.dispose();
        await BlocScope.reset();
      },
    );
  }
}
