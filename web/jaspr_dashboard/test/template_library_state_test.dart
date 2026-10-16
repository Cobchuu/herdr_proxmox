import 'package:test/test.dart';
import 'package:herdr_dashboard_state/template_library_state.dart';
import 'package:herdr_dashboard_state/team_template_draft.dart';

void main() {
  test('acknowledged saves advance versions without owning the draft', () {
    final state = TemplateLibraryState();
    final selected = state.selection;
    expect(state.acknowledge({'id': 'saved', 'version': 1}, selected), isTrue);
    expect(state.source!['version'], 1);
    expect(state.acknowledge({'id': 'saved', 'version': 2}, selected), isTrue);
    expect(state.source!['version'], 2);
  });

  test('an old save cannot replace a different selected template', () {
    final state = TemplateLibraryState();
    final selected = state.selection;
    state.source = {'id': 'different', 'version': 3};
    expect(
      state.acknowledge({'id': 'old-save', 'version': 1}, selected),
      isFalse,
    );
    expect(state.source!['id'], 'different');
  });

  test('stale completion cannot clear a newer operation busy state', () {
    final state = TemplateLibraryState();
    final old = state.begin();
    final current = state.begin();
    state.finish(old);
    expect(state.busy, isTrue);
    expect(state.current(old), isFalse);
    state.finish(current);
    expect(state.busy, isFalse);
  });

  test('lost-response retries freeze intent and reuse its request ID', () {
    final state = TemplateLibraryState();
    var sequence = 0;
    final intent = <String, dynamic>{
      'definition': {'name': 'Original'},
    };
    String id() => 'request-${++sequence}';
    final first = state.request(intent, id);
    (intent['definition'] as Map)['name'] = 'Edited';
    expect((first['definition'] as Map)['name'], 'Original');
    final replay = state.request({
      'definition': {'name': 'Original'},
    }, id);
    expect(replay['request_id'], first['request_id']);
    expect(state.request(intent, id)['request_id'], isNot(first['request_id']));
  });

  test(
    'retry identity ignores nested map key order but preserves list order',
    () {
      final state = TemplateLibraryState();
      var sequence = 0;
      String id() => 'request-${++sequence}';
      final first = state.request({
        'name': 'Team',
        'definition': {
          'team_members': [
            {'key': 'one', 'persona': 'Custom'},
            {'key': 'two', 'persona': 'Other'},
          ],
          'model_policy': 'balanced',
        },
      }, id);
      final reordered = <String, dynamic>{
        'definition': {
          'model_policy': 'balanced',
          'team_members': [
            {'persona': 'Custom', 'key': 'one'},
            {'persona': 'Other', 'key': 'two'},
          ],
        },
        'name': 'Team',
      };
      expect(state.request(reordered, id)['request_id'], first['request_id']);
      expect(sequence, 1);
      final members = (reordered['definition'] as Map)['team_members'] as List;
      (reordered['definition'] as Map)['team_members'] = members.reversed
          .toList();
      expect(
        state.request(reordered, id)['request_id'],
        isNot(first['request_id']),
      );
    },
  );

  test('execution summary describes worktree, permission and path overrides', () {
    expect(
      memberExecutionSummary({}),
      'Separate worktree · CLI default permissions',
    );
    expect(
      memberExecutionSummary({
        'use_worktree': false,
        'permission_mode': 'full_autonomy',
        'accessible_paths': ['/shared/**'],
      }),
      'Shared project directory · Full autonomy · Additional access: /shared/**',
    );
  });

  test('role toggles retain customized duplicates and reporting IDs', () {
    final draft = TeamTemplateDraft([
      {'id': 'lead', 'name': 'Lead'},
      {'id': 'backend', 'name': 'Backend'},
    ]);
    draft.syncRoles(['lead', 'backend']);
    final lead = draft.members.first;
    draft.members.last.addAll({
      'name': 'Maya',
      'persona': 'Custom work',
      'runtime': 'codex',
      'manager_key': lead['key'],
    });
    draft.add('backend', draft.members.last);
    final before = draft.members
        .where((m) => m['template_role'] == 'backend')
        .map((m) => Map.from(m))
        .toList();
    draft.syncRoles(['lead']);
    expect(draft.members, hasLength(1));
    draft.syncRoles(['lead', 'backend']);
    expect(draft.members.skip(1).toList(), before);
    draft.syncRoles(['lead']);
    draft.remove('${lead['key']}');
    draft.syncRoles(['backend']);
    expect(draft.members.every((m) => !m.containsKey('manager_key')), isTrue);
  });

  test(
    'bundle replacement clears detached members and restoration respects capacity',
    () {
      final draft = TeamTemplateDraft([
        {'id': 'backend', 'name': 'Backend'},
        {'id': 'lead', 'name': 'Lead'},
      ], maxMembers: 2);
      draft.syncRoles(['backend']);
      draft.members.first['name'] = 'Old customization';
      draft.add('backend');
      draft.syncRoles([]);
      draft.syncRoles(['lead']);
      expect(draft.syncRoles(['lead', 'backend']), isFalse);
      expect(draft.members, hasLength(1));
      expect(draft.syncRoles(['backend']), isTrue);
      expect(draft.members, hasLength(2));
      expect(draft.members.first['name'], 'Old customization');
      draft.syncRoles([]);
      draft.applyBundle({'members': []});
      draft.syncRoles(['backend']);
      expect(draft.members.first.containsKey('name'), isFalse);
    },
  );

  test('capacity refusal is atomic for every role restoration order', () {
    for (final selected in [
      ['lead', 'qa', 'backend'],
      ['lead', 'backend', 'qa'],
      ['qa', 'backend', 'new'],
    ]) {
      final draft = TeamTemplateDraft([
        {'id': 'backend', 'name': 'Backend'},
        {'id': 'qa', 'name': 'QA'},
        {'id': 'lead', 'name': 'Lead'},
        {'id': 'new', 'name': 'New role'},
      ], maxMembers: 3);
      draft.syncRoles(['backend', 'qa']);
      draft.members.first['persona'] = 'Customized backend';
      draft.add('backend');
      final saved = draft.members.map((m) => Map.from(m)).toList();
      draft.syncRoles(['lead']);
      final active = draft.members.map((m) => Map.from(m)).toList();
      expect(draft.syncRoles(selected), isFalse, reason: '$selected');
      expect(draft.members, active);
      expect(draft.selectedRoles, ['lead']);
      expect(draft.syncRoles(['backend', 'qa']), isTrue);
      expect(draft.members, [saved[0], saved[2], saved[1]]);
    }
  });
}
