/// Framework-independent member drafts. Resolved model choices never become
/// overrides unless the user explicitly edits them.
class TeamTemplateDraft {
  TeamTemplateDraft(this.roles, {this.maxMembers = 20});
  final List<Map<String, dynamic>> roles;
  final int maxMembers;
  final members = <Map<String, dynamic>>[];
  int _sequence = 0;

  Map<String, dynamic> role(String id) =>
      roles.firstWhere((r) => r['id'] == id);
  List<String> get selectedRoles =>
      members.map((m) => '${m['template_role']}').toSet().toList();
  bool syncRoles(Iterable<String> selected) {
    final ids = selected.toSet();
    members.removeWhere((m) => !ids.contains(m['template_role']));
    for (final id in ids) {
      if (!members.any((m) => m['template_role'] == id)) add(id);
    }
    return ids.every((id) => members.any((m) => m['template_role'] == id));
  }

  bool add(String roleId, [Map<String, dynamic>? source]) {
    if (members.length >= maxMembers) return false;
    var key = '${roleId}_${++_sequence}';
    while (members.any((m) => m['key'] == key)) {
      key = '${roleId}_${++_sequence}';
    }
    members.add(
      {...?source, 'key': key, 'template_role': roleId}..remove('name'),
    );
    return true;
  }

  void remove(String key) {
    members.removeWhere((m) => m['key'] == key);
    for (final member in members) {
      if (member['manager_key'] == key) member.remove('manager_key');
    }
  }

  void hydrate(dynamic specs) {
    if (specs is! List) return;
    members
      ..clear()
      ..addAll([for (final spec in specs) Map<String, dynamic>.from(spec)]);
  }

  String name(Map<String, dynamic> member) {
    if (member['name'] != null) return '${member['name']}';
    final same = members
        .where((m) => m['template_role'] == member['template_role'])
        .toList();
    final ordinal = same.indexWhere((m) => m['key'] == member['key']) + 1;
    return '${role('${member['template_role']}')['name']}${ordinal > 1 ? ' $ordinal' : ''}';
  }

  Map<String, dynamic> get payload => {
    'template_roles': selectedRoles,
    'team_members': [
      for (final member in members) Map<String, dynamic>.from(member),
    ],
  };
}
