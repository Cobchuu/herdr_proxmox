import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_dashboard_state/project_directory_choices.dart';

void main() {
  test(
    'explorer folders become sorted absolute paths, excluding non-project entries',
    () {
      expect(
        projectDirectoryChoices({
          'root': '/opt/herdr/projects/',
          'kind': 'folder',
          'entries': [
            {'name': 'Zulu', 'path': 'Zulu', 'kind': 'folder'},
            {'name': 'app', 'path': 'app', 'kind': 'folder'},
            {'name': '.git', 'path': '.git', 'kind': 'folder'},
            {'name': 'readme', 'path': 'readme', 'kind': 'file'},
            {'name': 'link', 'path': 'link', 'kind': 'link'},
          ],
        }).keys,
        ['/opt/herdr/projects/app', '/opt/herdr/projects/Zulu'],
      );
    },
  );
  test('missing or empty explorer listings have no selectable project', () {
    expect(projectDirectoryChoices({}), isEmpty);
    expect(
      projectDirectoryChoices({
        'root': '/projects',
        'kind': 'folder',
        'entries': [],
      }),
      isEmpty,
    );
  });
}
