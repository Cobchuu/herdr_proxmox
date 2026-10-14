import 'package:web/web.dart' as web;

String? readTheme() {
  try {
    return web.window.localStorage.getItem('herdr.theme');
  } catch (_) {
    return null;
  }
}

void writeTheme(String value) {
  // Appearance is optional; blocked browser storage must not break navigation.
  try {
    web.window.localStorage.setItem('herdr.theme', value);
  } catch (_) {}
}

/// Whether the wide-screen sidebar is collapsed (index.html applies it early).
bool readSidebarCollapsed() {
  try {
    return web.window.localStorage.getItem('herdr.sidebar') == 'collapsed';
  } catch (_) {
    return false;
  }
}

void writeSidebarCollapsed(bool collapsed) {
  try {
    if (collapsed)
      web.window.localStorage.setItem('herdr.sidebar', 'collapsed');
    else
      web.window.localStorage.removeItem('herdr.sidebar');
  } catch (_) {}
}
