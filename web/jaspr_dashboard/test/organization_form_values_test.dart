import 'package:test/test.dart';
import 'package:herdr_jaspr_dashboard/pages/org_form_values.dart';

void main() {
  test(
    'existing OpenCode policies stay; switching runtimes clears stale settings',
    () {
      final values = <String, dynamic>{
        'provider': 'saved',
        'model': 'saved',
        'reasoning': 'high',
        'permission_mode': 'full_autonomy',
        'accessible_paths': '/reference/**',
      };
      updateHireRuntime(values, 'opencode', creating: false);
      expect(values['permission_mode'], 'full_autonomy');
      expect(values['accessible_paths'], '/reference/**');
      updateHireRuntime(values, 'codex', creating: false);
      expect(values['provider'], '');
      expect(values['model'], '');
      expect(values['reasoning'], '');
      expect(values['permission_mode'], 'default');
      expect(values['accessible_paths'], '');
    },
  );
  test(
    'path form deduplicates globs and rejects invalid external directories',
    () {
      expect(parseAccessiblePaths(' /a/**\n~/docs/**\n/a/**\n'), [
        '/a/**',
        '~/docs/**',
      ]);
      expect(validateAccessiblePaths(r'$HOME/docs/**'), isNull);
      expect(validateAccessiblePaths('relative/path'), isNotNull);
      expect(validateAccessiblePaths('/a\u0000'), isNotNull);
      expect(
        validateAccessiblePaths(
          List.generate(21, (i) => '/path/$i').join('\n'),
        ),
        isNotNull,
      );
    },
  );
  test(
    'configuration preview counts every entry and rejects unsupported backups',
    () {
      expect(
        configurationImportSummary({
          'format': 'herdr-configuration',
          'version': 1,
          'organizations': [{}, {}],
          'profiles': [
            {},
            {'removed_at': 'yesterday'},
            {},
          ],
          'groups': [{}],
        }),
        '2 organizations, 3 agents, 1 groups.',
      );
      expect(
        () => configurationImportSummary({'format': 'other', 'version': 1}),
        throwsFormatException,
      );
      expect(
        () => configurationImportSummary({
          'format': 'herdr-configuration',
          'version': 2,
        }),
        throwsFormatException,
      );
    },
  );

  group('runtime choices', () {
    Map<String, dynamic> cli(String id, String name, [String? problem]) => {
      'id': id,
      'name': name,
      'installed': true,
      'ready': problem,
    };

    test('offers only runtimes the gateway reports as ready', () {
      final choices = runtimeChoices([
        cli('codex', 'Codex'),
        cli('claude', 'Claude Code', 'Claude Code has no Herdr integration, so its '
            'sessions cannot report state or be resumed.'),
        cli('agy', 'Antigravity', 'Antigravity is not installed. Install the CLI '
            'before adding an agent.'),
      ], null);
      expect(choices.keys, containsAll(['', 'codex']));
      expect(choices.keys, isNot(contains('claude')));
      expect(choices.keys, isNot(contains('agy')));
      expect(choices['codex'], 'Codex');
    });

    test('an edited agent keeps its runtime, labelled with the reason', () {
      final choices = runtimeChoices([
        cli('codex', 'Codex'),
        cli('agy', 'Antigravity', 'Antigravity has no Herdr integration.'),
      ], {'runtime': 'agy'});
      expect(choices['agy'], contains('Antigravity'));
      expect(choices['agy'], contains('no Herdr integration'));
      expect(choices['codex'], 'Codex');
    });

    test('says so rather than offering an empty list', () {
      final choices = runtimeChoices([
        cli('agy', 'Antigravity', 'Antigravity is not installed.'),
      ], null);
      expect(choices.keys, ['']);
      expect(choices[''], contains('No runtime is ready'));
    });

    test('a missing snapshot leaves the choice open to the server', () {
      expect(runtimeChoices(const [], null), {
        '': 'No runtime is ready - connect a CLI account first',
      });
    });
  });
}
