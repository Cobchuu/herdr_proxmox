/// Selectable project folders from the project explorer's root listing.
Map<String, String> projectDirectoryChoices(Map<String, dynamic> listing) {
  final root = '${listing['root'] ?? ''}'.replaceFirst(RegExp(r'/+$'), '');
  if (root.isEmpty || listing['kind'] != 'folder') return {};
  final folders =
      [
        for (final entry in listing['entries'] as List? ?? [])
          if (entry is Map &&
              entry['kind'] == 'folder' &&
              !'${entry['name']}'.startsWith('.'))
            entry,
      ]..sort(
        (a, b) => '${a['name']}'.toLowerCase().compareTo(
          '${b['name']}'.toLowerCase(),
        ),
      );
  return {
    for (final folder in folders)
      '$root/${folder['path']}': '$root/${folder['path']}',
  };
}
