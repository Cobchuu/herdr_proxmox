/// Framework-independent form rules copied from the existing dashboard UI.
/// They prepare form values; gateway repositories and blocs still own actions.
void updateHireRuntime(
  Map<String, dynamic> values,
  String runtime, {
  required bool creating,
}) {
  for (final key in ['provider', 'model', 'reasoning']) values[key] = '';
  if (creating && runtime == 'opencode')
    values['permission_mode'] = 'dashboard_outputs';
  if (runtime != 'opencode') {
    values['permission_mode'] = 'default';
    values['accessible_paths'] = '';
  }
}

List<String> parseAccessiblePaths(String source) => source
    .split('\n')
    .map((p) => p.trim())
    .where((p) => p.isNotEmpty)
    .toSet()
    .toList();
String? validateAccessiblePaths(String source) {
  final p = parseAccessiblePaths(source);
  if (p.length > 20) return 'Use at most 20 patterns.';
  if (p.any(
    (p) =>
        p.length > 500 ||
        p.contains('\u0000') ||
        !(p.startsWith('/') || p.startsWith('~/') || p.startsWith(r'$HOME/')),
  ))
    return 'Use absolute or home-relative patterns under 500 characters.';
  return null;
}

String configurationImportSummary(Map<String, dynamic> data) {
  if (data['format'] != 'herdr-configuration' || data['version'] != 1)
    throw const FormatException('Unsupported configuration format.');
  return '${(data['organizations'] as List).length} organizations, ${(data['profiles'] as List).length} agents, ${(data['groups'] as List).length} groups.';
}
