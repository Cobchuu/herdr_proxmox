import 'package:juice/juice.dart';
import 'package:web/web.dart' as web;

final routeChanges = ValueNotifier<int>(0);
Uri get currentRoute {
  final hash = web.window.location.hash;
  try {
    return Uri.parse(hash.length > 1 ? hash.substring(1) : '/');
  } catch (_) {
    return Uri(path: '/');
  }
}

void navigate(String route, {bool replace = false}) {
  if (replace) {
    web.window.history.replaceState(null, '', '#$route');
    routeChanges.value++;
  } else {
    web.window.location.hash = route;
  }
}
