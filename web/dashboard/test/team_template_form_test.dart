import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_dashboard/organization_page.dart';

void main() {
  testWidgets(
    'load a pinned saved template without losing fallback CLI preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const identifier = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      Map<String, dynamic>? saved, previewBody;
      final definition = {
        'team_members': [
          {
            'key': 'lead',
            'template_role': 'lead_developer',
            'name': 'Maya',
            'persona': 'Plan delivery.',
            'manager_key': '',
          },
        ],
        'model_policy': 'balanced',
        'runtime_preferences': ['codex', 'claude'],
        'resource_limits': {
          'max_active_sessions': 3,
          'max_active_meetings': 1,
          'daily_session_cap': 20,
        },
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => OrganizationForm(
                      templates: {
                        'roles': [
                          {'id': 'lead_developer', 'name': 'Lead Developer'},
                        ],
                        'policies': {'balanced': 'Balanced'},
                        'runtime_names': {
                          'codex': 'Codex',
                          'claude': 'Claude Code',
                        },
                        'saved_templates': [
                          {
                            'id': identifier,
                            'name': 'API team',
                            'version': 1,
                            'versions': [
                              {'version': 1, 'name': 'API team'},
                            ],
                          },
                        ],
                      },
                      canManageTemplates: false,
                      library: (body) async => {
                        'id': identifier,
                        'version': 1,
                        'latest_version': 1,
                        'name': 'API team',
                        'description': 'API specialists',
                        'definition': definition,
                      },
                      preview: (body) async {
                        previewBody = body;
                        return {
                          'template_plan': 'saved-plan',
                          'members': [],
                          'member_specs': definition['team_members'],
                        };
                      },
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'New team');
      await tester.enterText(find.byType(TextFormField).at(1), 'Build');
      await tester.tap(
        find.widgetWithText(
          DropdownButtonFormField<String>,
          'Saved template version',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('API team · v1').last);
      await tester.pumpAndSettle();
      expect(find.text('Configure Maya'), findsOneWidget);
      expect(find.text('Save reusable template'), findsNothing);
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Team project directory'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Team project directory'),
        '/projects/other',
      );
      await tester.ensureVisible(find.text('Preview team'));
      await tester.tap(find.text('Preview team'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save organization'));
      await tester.pumpAndSettle();
      expect(previewBody?['template_version'], 1);
      expect(saved?['template_id'], identifier);
      expect(saved?['runtime_preferences'], ['codex', 'claude']);
      expect((saved?['resource_limits'] as Map)['max_active_sessions'], 3);
      expect((saved?['team_members'] as List).single['name'], 'Maya');
    },
  );
  testWidgets(
    'role presets require a current preview and submit one team request',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? saved;
      final previews = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => OrganizationForm(
                      templates: {
                        'roles': [
                          {'id': 'lead_developer', 'name': 'Lead Developer'},
                        ],
                        'policies': {
                          'balanced': 'Balanced',
                          'economy': 'Lowest cost',
                        },
                      },
                      preview: (body) async {
                        previews.add(body);
                        return {
                          'template_plan': 'preview-digest',
                          'members': [
                            {
                              'name': 'Lead Developer',
                              'runtime': 'claude',
                              'model_name': 'Sonnet',
                              'manager_role': '',
                              'reasoning': 'high',
                              'selection_note': 'Balanced choice',
                              'persona':
                                  'Plan and coordinate. Report to the owner.',
                            },
                          ],
                          'warnings': [],
                        };
                      },
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'Engineering');
      await tester.enterText(find.byType(TextFormField).at(1), 'Build tools');
      await tester.tap(find.text('Lead Developer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Team project directory'),
        '/projects/app',
      );
      await tester.tap(find.text('Save organization'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(
        find.text('Preview the selected team before saving.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Preview team'));
      await tester.pumpAndSettle();
      expect(find.text('Lead Developer · claude · Sonnet'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Team project directory'),
        '/projects/other',
      );
      await tester.pumpAndSettle();
      expect(find.text('Lead Developer · claude · Sonnet'), findsNothing);
      await tester.tap(find.text('Preview team'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save organization'));
      await tester.pumpAndSettle();
      expect(saved?['template_roles'], ['lead_developer']);
      expect(saved?['model_policy'], 'balanced');
      expect(saved?['project'], '/projects/other');
      expect(saved?['template_plan'], 'preview-digest');
      expect(previews.length, 2);
      expect(saved?.containsKey('persona'), false);
    },
  );
}
