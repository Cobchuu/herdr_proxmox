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
}
