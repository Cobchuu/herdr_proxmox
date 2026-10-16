import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:herdr_dashboard/dashboard_bloc.dart';
import 'package:herdr_dashboard/project_analysis_card.dart';

void main() {
  testWidgets(
    'discovery shows evidence, lookup, readiness and coverage',
    (tester) async {
      var failed = false;
      var refreshRequested = false;
      final connection = DashboardBloc(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/analysis')) {
            refreshRequested |= request.url.queryParameters['refresh'] == '1';
            if (failed)
              return http.Response('{"error":"scan unavailable"}', 400);
            return http.Response(
              jsonEncode({
                'source': {
                  'scope': 'working_tree',
                  'at': '2026-10-16',
                  'cache_seconds': 30,
                  'boundary': 'repository root',
                },
                'coverage': {
                  'files': 3,
                  'directories': 2,
                  'unknown': 1,
                  'truncated': true,
                },
                // The resolved view the gateway serves: discovery plus the host
                // assessment, so readiness is measured rather than declared.
                'requirements': [
                  {
                    'tool': 'dotnet',
                    'label': '.NET SDK',
                    'constraint': '8.0.100',
                    'notation': 'dotnet',
                    'components': ['Api'],
                    'override': null,
                    'conflicts': [],
                    'assessment': {
                      'verdict': 'missing',
                      'measured': null,
                      'selected': '',
                      'detail': 'No dotnet executable answered a version request.',
                      'installer': false,
                      'provisionable': false,
                      'offer': null,
                    },
                  },
                ],
                'provisionable': [],
                'components': [
                  {
                    'path': 'Api',
                    'basis': 'manifest',
                    'languages': [
                      {'label': 'C#'},
                    ],
                    'requirements': [
                      {
                        'tool': 'dotnet',
                        'label': '.NET SDK',
                        'selected': '8.0.100',
                        'established': true,
                        'observations': [
                          {'file': 'global.json', 'field': 'sdk.version'},
                        ],
                        'resolution': {
                          'context': {'directory': 'Api'},
                          'boundary': 'repository root',
                          'boundary_note':
                              'Host configuration above the repository root is not inspected.',
                          'shadowed': [],
                        },
                      },
                    ],
                    'unresolved': [],
                  },
                ],
                'unresolved': [
                  {
                    'what': 'directory listing',
                    'reason': 'Listing was capped.',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{"workspaces":[],"agents":[]}', 200);
        }),
      );
      BlocScope.register<DashboardBloc>(() => connection);
      connection.connect('token');
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ProjectAnalysisCard(path: 'repo')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discovered requirements'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Evidence: global.json#sdk.version'),
        findsOneWidget,
      );
      expect(find.textContaining('SDK lookup: Api'), findsOneWidget);
      expect(find.textContaining('partial scan'), findsOneWidget);
      expect(find.text('Host readiness'), findsOneWidget);
      expect(find.textContaining('· missing'), findsOneWidget);
      expect(find.textContaining('Component: Api'), findsOneWidget);
      expect(find.textContaining('No installed version was measured'), findsOneWidget);
      expect(
        find.textContaining(
          'No requirement of this project is installable by this release',
        ),
        findsOneWidget,
      );
      final scroll = find.byType(SingleChildScrollView).first;
      await tester.scrollUntilVisible(
        find.text('Re-analyse'),
        120,
        scrollable: find
            .descendant(of: scroll, matching: find.byType(Scrollable))
            .first,
      );
      failed = true;
      await tester.tap(find.text('Re-analyse'));
      await tester.pumpAndSettle();
      expect(refreshRequested, isTrue);
      expect(
        find.textContaining('This does not mean no requirements exist'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await connection.disconnect();
      await BlocScope.reset();
    },
  );

  testWidgets('failed override save keeps the draft dialog open', (
    tester,
  ) async {
    final connection = DashboardBloc(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/toolchain'))
          return http.Response('{"error":"Unknown tool"}', 400);
        if (request.url.path.endsWith('/analysis'))
          return http.Response(
            '{"components":[],"coverage":{},"source":{},"requirements":[]}',
            200,
          );
        return http.Response('{"workspaces":[],"agents":[]}', 200);
      }),
    );
    BlocScope.register<DashboardBloc>(() => connection);
    connection.connect('token');
    connection.operator.value = {'role': 'admin'};
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ProjectAnalysisCard(path: 'repo')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discovered requirements'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add override'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'php');
    await tester.enterText(find.byType(TextField).last, '^8.2');
    await tester.tap(find.text('Save override'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Unknown tool'), findsOneWidget);
    expect(find.text('^8.2'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await connection.disconnect();
    await BlocScope.reset();
  });
}
