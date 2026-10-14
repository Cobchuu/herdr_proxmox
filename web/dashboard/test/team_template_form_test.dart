import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_dashboard/organization_page.dart';

void main() {
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
