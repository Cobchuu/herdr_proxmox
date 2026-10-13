import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'ui.dart';
import 'services.dart';
import 'navigation.dart';
import 'overview.dart';
import 'platform/theme_storage_web.dart' as themeStorage;
import 'pages/organization_page.dart';
import 'pages/group_page.dart';
import 'pages/agent_console_page.dart';
import 'pages/tasks_page.dart';
import 'pages/knowledge_page.dart';
import 'pages/builds_page.dart';
import 'pages/logs_page.dart';
import 'pages/cli_setup_page.dart';
import 'pages/project_explorer_page.dart';

class DashboardApp extends StatefulComponent {
  const DashboardApp({super.key});
  @override
  State<DashboardApp> createState() => _DashboardAppState();
}

class _DashboardAppState extends State<DashboardApp> {
  DashboardBloc get connection => dashboardConnection;
  final subscriptions = <StreamSubscription>[];
  late final JSFunction hashListener;
  bool restoring = true;
  bool drawer = false;
  bool loadingDirectory = false;
  bool polling = false;
  int noticeGeneration = -1;
  int sessionGeneration = -1;
  Timer? noticeTimer;
  String token = '';
  String theme = 'system';
  String navSearch = '';
  String? noticesChecked;
  List<IntegrationNotice> notices = [];
  final Set<String> seen = {};
  final Set<String> asking = {};

  @override
  void initState() {
    super.initState();
    final queryTheme = Uri.base.queryParameters['theme'];
    theme = ['light', 'dark'].contains(queryTheme)
        ? queryTheme!
        : themeStorage.readTheme() ?? 'system';
    applyTheme(theme, persist: false);
    hashListener = ((web.Event _) {
      routeChanged();
    }).toJS;
    web.window.addEventListener('hashchange', hashListener);
    subscriptions.add(
      connection.stream.listen((_) {
        if (!mounted) return;
        if (sessionGeneration != connection.generation) {
          sessionGeneration = connection.generation;
          closeDialogs();
          messages.value = null;
          asking.clear();
          notices = [];
          seen.clear();
          noticesChecked = null;
        }
        setState(() {});
        loadDirectory();
        if (noticeGeneration != connection.generation)
          pollNotices(announce: false);
      }),
    );
    connection.organizationDirectory.addListener(rebuild);
    connection.selectedOrganization.addListener(rebuild);
    connection.operator.addListener(rebuild);
    routeChanges.addListener(routeChanged);
    dialogChanges.addListener(rebuild);
    messages.addListener(rebuild);
    connection.notificationRevision.addListener(rebuild);
    connection.restoreSession().whenComplete(() {
      if (mounted) setState(() => restoring = false);
    });
    noticeTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => pollNotices(),
    );
  }

  void rebuild() {
    if (mounted) setState(() {});
  }

  void routeChanged() {
    if (!mounted) return;
    setState(() => drawer = false);
    scheduleMicrotask(() {
      (web.document.getElementById('content') as web.HTMLElement?)?.scrollTop =
          0;
    });
  }

  void applyTheme(String value, {bool persist = true}) {
    theme = value;
    if (['light', 'dark'].contains(value))
      web.document.documentElement?.setAttribute('data-theme', value);
    else
      web.document.documentElement?.removeAttribute('data-theme');
    if (persist) themeStorage.writeTheme(value);
    rebuild();
  }

  Future<void> loadDirectory() async {
    if (loadingDirectory ||
        !connection.state.connected ||
        connection.organizationDirectory.value['loaded'] == true)
      return;
    loadingDirectory = true;
    try {
      await connection.request('organizations/directory');
    } catch (_) {
    } finally {
      loadingDirectory = false;
    }
  }

  Future<void> pollNotices({bool announce = true}) async {
    if (!connection.state.connected) {
      if (notices.isNotEmpty || seen.isNotEmpty)
        setState(() {
          notices = [];
          seen.clear();
          noticesChecked = null;
        });
      return;
    }
    if (noticeGeneration != connection.generation) {
      noticeGeneration = connection.generation;
      setState(() {
        notices = [];
        seen.clear();
        noticesChecked = null;
      });
    }
    if (polling) return;
    final epoch = connection.generation;
    polling = true;
    try {
      final result = await connection.request('integration');
      if (!mounted ||
          epoch != connection.generation ||
          !connection.state.connected)
        return;
      final next = [
        for (final notice in (result['alerts'] as List? ?? []))
          if (notice is Map<String, dynamic>)
            IntegrationNotice.fromJson(notice),
      ];
      seen.removeWhere((key) => !next.any((notice) => notice.key == key));
      final fresh = next.where((notice) => seen.add(notice.key)).toList();
      setState(() {
        notices = next;
        noticesChecked = result['checked'] as String?;
      });
      refreshDialogs();
      if (announce && fresh.isNotEmpty)
        toast(
          fresh.length == 1
              ? 'Integration notice: ${fresh.first.summary}'
              : '${fresh.length} integration notices need review',
        );
    } catch (_) {
    } finally {
      polling = false;
    }
  }

  Future<void> askIntegration(IntegrationNotice notice) async {
    if (asking.contains(notice.profileId)) return;
    final epoch = connection.generation;
    setState(() => asking.add(notice.profileId));
    refreshDialogs();
    try {
      await requestIntegration(connection, notice);
      if (!mounted || epoch != connection.generation) return;
      toast(
        'Asked ${notice.name.isEmpty ? 'the agent' : notice.name} to integrate.',
      );
    } catch (error) {
      if (mounted && epoch == connection.generation)
        toast('Integration request failed: $error');
    } finally {
      if (mounted && epoch == connection.generation) {
        setState(() => asking.remove(notice.profileId));
        refreshDialogs();
      }
    }
  }

  Future<void> showNotices() => showDialog<void>(
    'Integration notices',
    (close) => el('div', [
      el('p', [text('Agents keep working. Nothing is merged automatically.')]),
      if (noticesChecked != null)
        el('p', [
          text(
            'Checked ${DateTime.tryParse(noticesChecked!)?.toLocal() ?? noticesChecked}',
          ),
        ], classes: 'muted'),
      if (notices.isEmpty)
        text('No integration notices were found in the last check.'),
      for (final notice in notices)
        card(notice.name.isEmpty ? notice.path : notice.name, [
          el('code', [text('${notice.path} · ${notice.branch}')]),
          el('p', [text(notice.summary)]),
          el('p', [
            text(
              notice.lastFetch == null
                  ? 'Remote comparison has no recorded fetch time.'
                  : 'Remote last fetched: ${DateTime.tryParse(notice.lastFetch!)?.toLocal() ?? notice.lastFetch}',
            ),
          ], classes: 'muted'),
          el('div', [
            if (connection.operator.value['role'] == 'admin')
              button(
                agentCanIntegrate(connection, notice.profileId)
                    ? 'Ask to integrate'
                    : 'Busy; ask later to integrate',
                () => askIntegration(notice),
                disabled:
                    !agentCanIntegrate(connection, notice.profileId) ||
                    asking.contains(notice.profileId),
              ),
            button(
              'Copy instructions',
              () async => toast(
                await copyText(
                  notice.instructions,
                  filename: 'integration-instructions.md',
                ),
              ),
            ),
            button('Open Git changes', () {
              close(null);
              navigate(
                Uri(
                  path: '/explorer',
                  queryParameters: {'path': notice.path},
                ).toString(),
              );
            }),
          ], classes: 'actions'),
        ]),
      button('Close', () => close(null)),
    ]),
  ).then((_) {});

  @override
  void dispose() {
    noticeTimer?.cancel();
    for (final sub in subscriptions) unawaited(sub.cancel());
    web.window.removeEventListener('hashchange', hashListener);
    connection.organizationDirectory.removeListener(rebuild);
    connection.selectedOrganization.removeListener(rebuild);
    connection.operator.removeListener(rebuild);
    connection.notificationRevision.removeListener(rebuild);
    routeChanges.removeListener(routeChanged);
    dialogChanges.removeListener(rebuild);
    messages.removeListener(rebuild);
    super.dispose();
  }

  String get title {
    final path = currentRoute.path;
    if (path.startsWith('/knowledge/')) return 'Project knowledge';
    if (path.startsWith('/agents/')) return 'Agent console';
    if (path.startsWith('/groups/')) return 'Discussion group';
    if (path.startsWith('/tasks/')) return 'Task detail';
    return const {
          '/': 'Overview',
          '/agents': 'Agent activity',
          '/organization': 'Organization',
          '/tasks': 'Tasks',
          '/knowledge': 'Project knowledge',
          '/explorer': 'Project explorer',
          '/logs': 'Terminal logs',
          '/configuration': 'CLI accounts',
          '/builds': 'Builds & deployments',
        }[path] ??
        'Page not found';
  }

  Component _page() {
    final route = currentRoute;
    final key = Key('${route.toString()}:${connection.generation}');
    final segments = route.pathSegments;
    if (segments.length == 2 && segments.first == 'agents')
      return AgentConsolePage(id: segments[1], key: key);
    if (segments.length == 2 && segments.first == 'groups')
      return GroupPage(id: segments[1], key: key);
    if (segments.length == 2 && segments.first == 'tasks')
      return TasksPage(taskId: segments[1], key: key);
    if (segments.length == 2 && segments.first == 'knowledge')
      return KnowledgePage(organizationId: segments[1], key: key);
    return switch (route.path) {
      '/' || '' => OverviewPage(key: key),
      '/agents' => OverviewPage(agentsOnly: true, key: key),
      '/organization' => OrganizationPage(
        initialView: route.queryParameters['view'] ?? 'chart',
        key: key,
      ),
      '/tasks' => TasksPage(key: key),
      '/knowledge' => KnowledgePage(
        organizationId: route.queryParameters['organization'] ?? '',
        key: key,
      ),
      '/builds' => BuildsPage(key: key),
      '/logs' => LogsPage(key: key),
      '/configuration' => CliSetupPage(key: key),
      '/explorer' => ProjectExplorerPage(
        initialPath: route.queryParameters['path'] ?? '',
        key: key,
      ),
      _ => card('Page not found', [
        button('Return to dashboard', () => navigate('/', replace: true)),
      ]),
    };
  }

  Component _nav(String label, String name, String route) => el(
    'a',
    [icon(name), text(label)],
    classes: 'nav-item',
    attributes: {
      'href': '#$route',
      'aria-current': currentRoute.path == Uri.parse(route).path
          ? 'page'
          : 'false',
    },
  );
  Component _signIn() => el('div', [
    logo(),
    el('h1', [text('Connect to this container')]),
    if (restoring)
      notice('Checking your browser session…')
    else
      el(
        'form',
        [
          field(
            'Dashboard access token',
            token,
            (value) => token = value,
            password: true,
            required: true,
          ),
          el('p', [
            text('Stay signed in for 7 days. Sign out on shared devices.'),
          ], classes: 'muted'),
          el(
            'button',
            [text('Connect')],
            classes: 'btn btn--primary',
            attributes: {'type': 'submit'},
          ),
        ],
        events: {
          'submit': (event) {
            event.preventDefault();
            if (token.trim().isEmpty) return;
            final credential = token.trim();
            final form = event.target as web.HTMLFormElement;
            (form.querySelector('input') as web.HTMLInputElement?)?.value = '';
            setState(() => token = '');
            connection.signIn(credential);
          },
        },
      ),
  ], classes: 'login card');

  @override
  Component build(BuildContext context) {
    final state = connection.state;
    final directory = connection.organizationDirectory.value;
    final orgs = List<Map<String, dynamic>>.from(
      directory['organizations'] ?? [],
    );
    final org =
        orgs
            .where(
              (item) => item['id'] == connection.selectedOrganization.value,
            )
            .firstOrNull ??
        orgs.firstOrNull;
    final profiles =
        List<Map<String, dynamic>>.from(directory['profiles'] ?? [])
            .where(
              (item) =>
                  item['organization_id'] == org?['id'] &&
                  item['group_id'] == null,
            )
            .toList();
    final groups = List<Map<String, dynamic>>.from(
      directory['groups'] ?? [],
    ).where((item) => item['organization_id'] == org?['id']).toList();
    final archived = List<Map<String, dynamic>>.from(
      directory['archived_groups'] ?? [],
    ).where((item) => item['organization_id'] == org?['id']).toList();
    final needle = navSearch.trim().toLowerCase();
    return el('div', [
      el(
        'a',
        [text('Skip to content')],
        classes: 'skip-link',
        attributes: {'href': '#content'},
        events: {
          'click': (event) {
            event.preventDefault();
            (web.document.getElementById('content') as web.HTMLElement?)
                ?.focus();
          },
        },
      ),
      el(
        'aside',
        [
          el(
            'a',
            [logo()],
            attributes: {'href': '#/', 'aria-label': 'Herdr home'},
            classes: 'rail-brand',
          ),
          for (final item in orgs)
            el(
              'button',
              [
                text(
                  '${item['name']}'.trim().isEmpty
                      ? '?'
                      : '${item['name']}'.trim().substring(0, 1).toUpperCase(),
                ),
              ],
              classes:
                  'rail-tile ${item['id'] == org?['id'] ? 'is-selected' : ''}',
              attributes: {
                'type': 'button',
                'title': '${item['name']}',
                'aria-label': 'Select ${item['name']}',
              },
              events: {
                'click': (_) {
                  connection.selectedOrganization.value = item['id'] as String;
                  navigate('/organization');
                },
              },
            ),
          el(
            'a',
            [icon('plus')],
            classes: 'rail-add',
            attributes: {
              'href': '#/organization',
              'aria-label': 'Manage organizations',
            },
          ),
          el(
            'a',
            [icon('settings')],
            classes: 'rail-settings',
            attributes: {'href': '#/configuration', 'aria-label': 'Settings'},
          ),
        ],
        classes: 'rail',
        attributes: {'aria-label': 'Organizations'},
      ),
      el(
        'aside',
        [
          el('div', [
            el('strong', [text('Herdr')], classes: 'wordmark'),
            button(
              'Close',
              () => setState(() => drawer = false),
              classes: 'drawer-close',
            ),
          ], classes: 'sidebar-brand'),
          el('div', [
            if (org != null)
              select(
                'Organization',
                '${org['id']}',
                {for (final item in orgs) '${item['id']}': '${item['name']}'},
                (value) {
                  connection.selectedOrganization.value = value;
                  navigate('/organization');
                },
              ),
            field(
              'Search navigation',
              navSearch,
              (value) => setState(() => navSearch = value),
              placeholder: 'Agent or group',
            ),
            el(
              'nav',
              [
                _nav('Overview', 'layout-dashboard', '/'),
                _nav('Org chart', 'network', '/organization'),
                _nav('Tasks', 'list-checks', '/tasks'),
                _nav('Project knowledge', 'book-open', '/knowledge'),
                _nav('Agent activity', 'activity', '/agents'),
                el('h3', [text('Workspace')]),
                _nav('Project explorer', 'folder', '/explorer'),
                _nav('Terminal logs', 'terminal', '/logs'),
                _nav('CLI accounts', 'key-round', '/configuration'),
                _nav('Builds & deployments', 'rocket', '/builds'),
                el('h3', [text('Agents')]),
                if (profiles.isEmpty)
                  el('p', [text('Hire your first agent')], classes: 'muted'),
                for (final profile in profiles.where(
                  (p) => '$p'.toLowerCase().contains(needle),
                ))
                  el(
                    'a',
                    [
                      el(
                        'span',
                        [],
                        classes: 'status-dot',
                        attributes: {
                          'data-tone': toneFor(
                            activityFor(
                              connection.state.agents
                                      .where(
                                        (a) => a['profile_id'] == profile['id'],
                                      )
                                      .firstOrNull ??
                                  {},
                            ),
                          ),
                        },
                      ),
                      text(profile['name']),
                    ],
                    classes: 'nav-item',
                    attributes: {
                      'href':
                          '#/agents/${Uri.encodeComponent('${profile['id']}')}',
                    },
                  ),
                el('h3', [text('Groups')]),
                if (groups.isEmpty)
                  el('p', [text('No discussion groups yet')], classes: 'muted'),
                for (final group in groups.where(
                  (g) => '$g'.toLowerCase().contains(needle),
                ))
                  _nav(
                    '${group['name']}',
                    'message-square',
                    '/groups/${Uri.encodeComponent('${group['id']}')}',
                  ),
                if (archived.isNotEmpty) el('h3', [text('Archived groups')]),
                for (final group in archived.where(
                  (g) => '$g'.toLowerCase().contains(needle),
                ))
                  _nav(
                    '${group['name']}',
                    'archive',
                    '/groups/${Uri.encodeComponent('${group['id']}')}',
                  ),
              ],
              attributes: {'aria-label': 'Main navigation'},
            ),
          ], classes: 'sidebar-scroll'),
          if (state.connected)
            el('div', [
              el('strong', [text(connection.operator.value['name'])]),
              el('span', [
                text(connection.operator.value['role']),
              ], classes: 'muted'),
              button('Sign out', connection.disconnect),
            ], classes: 'sidebar-user'),
        ],
        classes: 'sidebar ${drawer ? 'is-open' : ''}',
        attributes: {'aria-label': 'Sidebar'},
      ),
      if (drawer)
        el(
          'button',
          [],
          classes: 'drawer-scrim',
          attributes: {'aria-label': 'Close navigation'},
          events: {'click': (_) => setState(() => drawer = false)},
        ),
      el('div', [
        el('header', [
          button(
            'Menu',
            () => setState(() => drawer = !drawer),
            classes: 'drawer-toggle',
          ),
          el('div', [
            if (org != null) text('${org['name']} / '),
            el('strong', [text(title)]),
          ], classes: 'breadcrumb'),
          badge(
            state.connected ? 'Connected' : 'Disconnected',
            tone: state.connected ? 'success' : 'neutral',
          ),
          el('div', [
            for (final mode in ['light', 'system', 'dark'])
              button(
                mode,
                () => applyTheme(mode),
                classes: theme == mode ? 'is-selected' : null,
              ),
          ], classes: 'theme-switch'),
          if (notices.isNotEmpty)
            button(
              '${notices.length} integration notices',
              showNotices,
              classes: 'notice-button',
            ),
        ], classes: 'topbar'),
        el(
          'main',
          [
            if (state.error != null) notice(state.error, error: true),
            if (messages.value != null)
              el('div', [
                notice(messages.value),
                button('Dismiss', () => messages.value = null),
              ], classes: 'toast'),
            if (state.connected) _page() else _signIn(),
          ],
          classes: 'main-content',
          attributes: {
            'id': 'content',
            'tabindex': '-1',
            'aria-busy': '${state.busy}',
          },
        ),
        el('footer', [
          text(
            'Herdr: ${state.serverStatus} · ${state.refreshed == null ? 'Waiting for first update' : 'Updated ${state.refreshed!.toLocal().toString().substring(11, 19)}'}',
          ),
          if (state.connected)
            button(
              'Refresh',
              () => connection.send(DashboardCommand('refresh')),
              disabled: state.busy,
            ),
        ], classes: 'statusbar'),
      ], classes: 'workspace'),
      buildDialogs(),
    ], classes: 'app');
  }
}
