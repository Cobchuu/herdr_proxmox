import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_dashboard_state/team_template_draft.dart';

void main() {
  final roles = [
    {'id': 'lead_developer', 'name': 'Lead Developer'},
    {'id': 'backend_developer', 'name': 'Backend Developer'},
  ];
  test('member duplicates preserve overrides and stable reporting IDs', () {
    final draft = TeamTemplateDraft(roles);
    draft.syncRoles(['lead_developer', 'backend_developer']);
    final lead = draft.members.first;
    final worker = draft.members.last;
    worker['manager_key'] = lead['key'];
    worker['runtime'] = 'codex';
    expect(draft.add('backend_developer', worker), true);
    expect(draft.name(draft.members.last), 'Backend Developer 2');
    expect(draft.members.last['runtime'], 'codex');
    expect(draft.members.last['key'], isNot(worker['key']));
    draft.remove('${lead['key']}');
    expect(draft.members.every((m) => !m.containsKey('manager_key')), true);
    expect(draft.payload['template_roles'], ['backend_developer']);
  });
  test('applying a team bundle replaces the roster and remains editable', () {
    final draft = TeamTemplateDraft(roles);
    draft.syncRoles(['backend_developer']);
    draft.members.first['name'] = 'Old draft';
    draft.applyBundle({
      'members': [
        {'key': 'lead_developer', 'template_role': 'lead_developer'},
        {'key': 'backend_developer', 'template_role': 'backend_developer'},
      ],
    });
    expect(draft.members.length, 2);
    expect(draft.members.any((m) => m['name'] == 'Old draft'), false);
    expect(draft.selectedRoles, ['lead_developer', 'backend_developer']);
    draft.add('backend_developer');
    expect(draft.members.length, 3);
  });
  test(
    'hydrated drafts preserve automatic choices and avoid duplicate keys',
    () {
      final draft = TeamTemplateDraft(roles, maxMembers: 2);
      draft.hydrate([
        {'key': 'backend_developer_1', 'template_role': 'backend_developer'},
      ]);
      draft.add('backend_developer');
      expect(draft.members.map((m) => m['key']).toSet().length, 2);
      expect(draft.add('lead_developer'), false);
      expect(draft.members.any((m) => m.containsKey('model')), false);
    },
  );
}
