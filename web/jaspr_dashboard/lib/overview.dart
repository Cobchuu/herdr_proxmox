import 'dart:async';
import 'dart:convert';
import 'package:jaspr/dom.dart' as dom;
import 'package:web/web.dart' as web;
import 'ui.dart';
import 'services.dart';
import 'navigation.dart';

String agentName(Map<String, dynamic> agent) =>
    '${agent['display_name'] ?? agent['name'] ?? agent['agent'] ?? agent['pane_id'] ?? 'Agent'}';
String agentStatus(Map<String, dynamic> agent) =>
    '${agent['agent_status'] ?? agent['state'] ?? agent['status'] ?? 'unknown'}';
String workspaceFor(Map<String, dynamic> agent) =>
    '${agent['workspace_id'] ?? '${agent['pane_id'] ?? ''}'.split(':').first}';
String activityFor(Map<String, dynamic> agent) =>
    switch (agent['agent_status'] ?? agent['state']) {
      'idle' || 'done' => 'idle',
      'working' || 'running' || 'busy' || 'thinking' => 'working',
      'blocked' => 'attention',
      _ => 'offline',
    };
String toneFor(String status) => switch (status) {
  'working' ||
  'running' ||
  'connected' ||
  'completed' ||
  'idle' ||
  'done' => 'success',
  'blocked' || 'attention' || 'failed' || 'error' => 'danger',
  'waiting' || 'queued' || 'pending' => 'warning',
  _ => 'neutral',
};

class OverviewPage extends StatefulComponent {
  const OverviewPage({this.agentsOnly = false, super.key});
  final bool agentsOnly;
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  String search = '';
  String filter = 'All';
  String label = '';
  String cwd = '/home/herdr/projects';
  bool creating = false;
  StreamSubscription? subscription;
  @override
  void initState() {
    super.initState();
    subscription = dashboardConnection.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  Future<void> action(String name, Map<String, dynamic> body) =>
      dashboardConnection.send(DashboardCommand(name, body));
  Future<void> rename(Map<String, dynamic> workspace) async {
    final epoch = dashboardConnection.generation;
    var value = '${workspace['label'] ?? ''}';
    final selected = await showDialog<String>(
      'Rename workspace',
      (close) => el(
        'form',
        [
          field(
            'Workspace label',
            value,
            (next) => value = next,
            required: true,
          ),
          el('div', [
            button('Cancel', () => close(null)),
            dom.button(
              [text('Save')],
              type: dom.ButtonType.submit,
              classes: 'btn btn--primary',
            ),
          ], classes: 'actions'),
        ],
        events: {
          'submit': (event) {
            event.preventDefault();
            if (value.trim().isNotEmpty) close(value.trim());
          },
        },
      ),
    );
    if (mounted &&
        epoch == dashboardConnection.generation &&
        selected != null &&
        selected.trim().isNotEmpty)
      await action('rename', {
        'id': workspace['workspace_id'],
        'label': selected.trim(),
      });
  }

  void openProject() {
    setState(() => creating = true);
    scheduleMicrotask(
      () => web.document
          .getElementById('overview-project-form')
          ?.scrollIntoView(),
    );
  }

  Component _agents() {
    final agents = dashboardConnection.state.agents.where((a) {
      final status = agentStatus(a);
      final matches =
          filter == 'All' ||
          (filter == 'Working'
              ? ['working', 'running', 'busy'].contains(status)
              : filter == 'Needs attention'
              ? status == 'blocked'
              : ['idle', 'done', 'waiting'].contains(status));
      final needle = search.trim().toLowerCase();
      return matches &&
          (agentName(a).toLowerCase().contains(needle) ||
              workspaceFor(a).toLowerCase().contains(needle));
    }).toList();
    return card(
      'Agents',
      [
        el('div', [
          field(
            'Search agents',
            search,
            (value) => setState(() => search = value),
            placeholder: 'Name or workspace',
          ),
          el('div', [
            for (final value in ['All', 'Working', 'Idle', 'Needs attention'])
              button(
                value,
                () => setState(() => filter = value),
                classes: filter == value ? 'is-selected' : null,
              ),
          ], classes: 'filters'),
        ], classes: 'agent-filters'),
        el('p', [
          text(
            'Showing ${agents.length} of ${dashboardConnection.state.agents.length}',
          ),
        ], classes: 'muted'),
        if (agents.isEmpty)
          el('div', [
            text(
              search.trim().isEmpty
                  ? 'No agents match this view.'
                  : 'No agents match "$search".',
            ),
            if (search.isNotEmpty)
              button('Clear search', () => setState(() => search = '')),
          ], classes: 'empty-state')
        else
          table(
            ['Agent', 'Workspace', 'Runtime', 'Status'],
            [
              for (final agent in agents)
                [
                  el('div', [
                    el('span', [
                      text(agentName(agent).substring(0, 1)),
                    ], classes: 'role-tile'),
                    if (agent['profile_id'] != null)
                      el(
                        'a',
                        [text(agentName(agent))],
                        attributes: {
                          'href':
                              '#/agents/${Uri.encodeComponent('${agent['profile_id']}')}',
                        },
                      )
                    else
                      text(agentName(agent)),
                  ], classes: 'identity'),
                  el('code', [text(workspaceFor(agent))]),
                  text(agent['agent'] ?? agent['runtime'] ?? '—'),
                  badge(agentStatus(agent), tone: toneFor(agentStatus(agent))),
                ],
            ],
          ),
      ],
      actions: [button('Manage', () => navigate('/organization'))],
    );
  }

  /// One linked segment of the overview stat strip.
  Component _stat(String label, String value, String meta) => el('li', [
    el('div', [
      el('span', [text(value)], classes: 'stat-strip__value'),
      el('span', [text(label)], classes: 'stat-strip__label'),
      el('span', [text(meta)], classes: 'stat-strip__meta'),
    ], classes: 'stat-strip__item'),
  ]);

  /// "Tuesday, 13 October" without pulling in a date-formatting package.
  String today() {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final now = DateTime.now();
    return '${weekdays[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }

  @override
  Component build(BuildContext context) {
    final state = dashboardConnection.state;
    final admin = dashboardConnection.operator.value['role'] == 'admin';
    final working = state.agents
        .where((a) => activityFor(a) == 'working')
        .length;
    final attention = state.agents
        .where((a) => agentStatus(a) == 'blocked')
        .length;
    return el('div', [
      el('header', [
        el('div', [
          el('p', [
            text(today()),
          ], classes: 'page-header__overline'),
          el('h1', [
            text(component.agentsOnly ? 'Agent activity' : 'Overview'),
          ], classes: 'page-header__title'),
          el('p', [
            text(
              '${state.agents.length} agents across ${state.workspaces.length} workspaces',
            ),
          ], classes: 'page-header__subtitle'),
        ], classes: 'page-header__text'),
        if (!component.agentsOnly)
          el('div', [
            if (state.refreshed != null)
              el('span', [
                text(
                  'Updated ${state.refreshed!.toLocal().toString().substring(11, 19)}',
                ),
              ], classes: 'updated'),
            button(
              'Refresh',
              () => action('refresh', {}),
              disabled: state.busy,
            ),
            if (admin) ...[
              button('Add project', openProject),
              button('Create workspace', openProject, primary: true),
            ],
          ], classes: 'page-header__actions'),
      ], classes: 'page-header'),
      if (!component.agentsOnly)
        el(
          'section',
          [
            el('span', [
              icon('activity'),
            ], classes: 'icon-tile icon-tile--lg runtime__tile', attributes: {
              'data-tone': state.serverStatus == 'running'
                  ? 'success'
                  : 'neutral',
            }),
            el('div', [
              el('h2', [
                text(
                  state.serverStatus == 'running'
                      ? 'Herdr is running'
                      : 'Herdr: ${state.serverStatus}',
                ),
              ], classes: 'runtime__title'),
              el('p', [
                text(
                  '${state.agents.where((a) => activityFor(a) == 'working').length} of '
                  '${state.agents.length} agents working',
                ),
              ], classes: 'runtime__meta'),
            ], classes: 'runtime__text'),
            if (state.serverStatus == 'stopped' && admin)
              button(
                'Start Herdr',
                () =>
                    dashboardConnection.send(DashboardCommand('start-server')),
                disabled: state.busy,
                primary: true,
              )
            else if (admin)
              button(
                'Stop',
                () =>
                    dashboardConnection.send(DashboardCommand('stop-server')),
                disabled: state.busy,
                classes: 'btn--danger',
              ),
          ],
          classes: 'runtime',
          attributes: {
            'data-state': state.serverStatus == 'running' ? 'running' : 'stopped',
          },
        ),
      if (!component.agentsOnly)
        el('div', [
          el('ul', [
            _stat(
              'Agents working',
              '$working/${state.agents.length}',
              '${state.agents.length - working} idle',
            ),
            _stat(
              'Needs attention',
              '$attention',
              attention == 1 ? 'agent blocked or failed' : 'agents blocked or failed',
            ),
            _stat(
              'Workspaces',
              '${state.workspaces.length}',
              '${state.agents.length} agents assigned',
            ),
            _stat(
              'Connection',
              state.connected ? 'Online' : 'Offline',
              state.refreshed == null
                  ? 'Waiting for first update'
                  : 'Updated ${state.refreshed!.toLocal().toString().substring(11, 19)}',
            ),
          ], classes: 'stat-strip', attributes: {'role': 'list'}),
        ], classes: 'overview-stats'),
      _agents(),
      if (!component.agentsOnly)
        el('div', [
          card(
            'Workspaces',
            [
              if (state.workspaces.isEmpty)
                el('p', [
                  text('No workspaces yet. Create a workspace to get started.'),
                ]),
              el('div', [
                for (final workspace in state.workspaces)
                  el('article', [
                    el('h3', [
                      text(workspace['label'] ?? workspace['workspace_id']),
                    ]),
                    el('p', [
                      text(
                        '${workspace['workspace_id']} · ${state.agents.where((a) => workspaceFor(a) == workspace['workspace_id']).length} agents',
                      ),
                    ], classes: 'muted'),
                    if (workspace['cwd'] != null)
                      el('code', [text(workspace['cwd'])]),
                    if (admin)
                      el('div', [
                        button(
                          'Focus',
                          () => action('focus', {
                            'id': workspace['workspace_id'],
                          }),
                          disabled: state.busy,
                        ),
                        button(
                          'Rename',
                          () => rename(workspace),
                          disabled: state.busy,
                        ),
                      ], classes: 'actions'),
                  ], classes: 'workspace-tile'),
              ], classes: 'workspace-grid'),
            ],
            actions: [button('View projects', () => navigate('/explorer'))],
          ),
          const RecentActivity(),
        ], classes: 'overview-grid'),
      const SystemHealth(),
      if (!component.agentsOnly && admin)
        el(
          'details',
          [
            el('summary', [text('Add a project or workspace')]),
            el(
              'form',
              [
                field(
                  'Workspace label',
                  label,
                  (value) => label = value,
                  required: true,
                ),
                field(
                  'Project directory',
                  cwd,
                  (value) => cwd = value,
                  required: true,
                ),
                dom.button(
                  [text('Create workspace')],
                  type: dom.ButtonType.submit,
                  disabled: state.busy,
                  classes: 'btn btn--primary',
                ),
              ],
              events: {
                'submit': (event) {
                  event.preventDefault();
                  if (!state.busy)
                    action('create', {
                      'label': label.trim(),
                      'cwd': cwd.trim(),
                    });
                },
              },
            ),
            CloneProjectCard(onCloned: (path) => setState(() => cwd = path)),
          ],
          classes: 'card',
          attributes: {'id': 'overview-project-form', if (creating) 'open': ''},
        ),
      el('details', [
        el('summary', [text('Terminal access')]),
        el('pre', [
          text('ssh herdr@<container-ip>\nThen: cd ~/projects && herdr'),
        ]),
      ], classes: 'card'),
    ], classes: 'page-stack');
  }
}

class RecentActivity extends StatefulComponent {
  const RecentActivity({super.key});
  @override
  State<RecentActivity> createState() => _RecentActivityState();
}

class _RecentActivityState extends State<RecentActivity> {
  StreamSubscription? subscription;
  Map<String, String>? previous;
  final List<({String text, DateTime time})> events = [];
  @override
  void initState() {
    super.initState();
    observe(dashboardConnection.state);
    subscription = dashboardConnection.stream.listen((_) {
      observe(dashboardConnection.state);
    });
  }

  void observe(DashboardState state) {
    if (state.refreshed == null) return;
    final current = {
      for (final a in state.agents)
        '${a['name'] ?? a['pane_id']}': '${agentName(a)} · ${agentStatus(a)}',
    };
    if (previous != null) {
      for (final entry in current.entries) {
        if (previous![entry.key] != entry.value)
          events.insert(0, (text: entry.value, time: state.refreshed!));
      }
      for (final key in previous!.keys.where(
        (key) => !current.containsKey(key),
      )) {
        events.insert(0, (
          text: '${previous![key]!.split(' · ').first} · no longer detected',
          time: state.refreshed!,
        ));
      }
      if (events.length > 8) events.removeRange(8, events.length);
    }
    previous = current;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => card('Recent activity', [
    el('p', [text('Changes observed on this page')], classes: 'muted'),
    if (events.isEmpty) el('p', [text('No activity changes observed yet.')]),
    for (final event in events.take(3))
      el('div', [
        text(event.text),
        el('time', [text(event.time.toLocal().toString().substring(11, 19))]),
      ], classes: 'activity-row'),
  ]);
}

class SystemHealth extends StatefulComponent {
  const SystemHealth({super.key});
  @override
  State<SystemHealth> createState() => _SystemHealthState();
}

class _SystemHealthState extends State<SystemHealth> {
  Timer? timer;
  Map<String, dynamic>? data;
  bool loading = false;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() => loading = true);
    final epoch = dashboardConnection.generation;
    try {
      final result = await dashboardConnection.request('resources');
      if (mounted && epoch == dashboardConnection.generation)
        setState(() {
          data = Map<String, dynamic>.from(result);
          error = null;
        });
      if (mounted && !(timer?.isActive ?? false))
        timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    } catch (_) {
      timer?.cancel();
      if (mounted && epoch == dashboardConnection.generation)
        setState(
          () => error =
              'Resource monitor unavailable; displayed values may be stale.',
        );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String bytes(dynamic value) =>
      '${((value as num? ?? 0) / 1048576).toStringAsFixed(0)} MiB';
  String percent(dynamic value) =>
      value == null ? 'Sampling…' : '${(value as num).toStringAsFixed(1)}%';
  double ratio(dynamic used, dynamic total) => (total as num? ?? 0) > 0
      ? ((used as num? ?? 0) / (total as num)).toDouble()
      : 0;
  Component meter(String label, double value) => el('div', [
    text(label),
    el(
      'meter',
      [],
      attributes: {
        'min': '0',
        'max': '1',
        'value': '${value.clamp(0, 1)}',
        'aria-label': label,
      },
    ),
  ], classes: 'metric-meter');
  @override
  Component build(BuildContext context) {
    final d = data;
    return card(
      'System health',
      [
        if (error != null) notice(error, error: true),
        if (d == null && error == null)
          text('Loading resource usage…')
        else if (d != null && d['available'] != true)
          text('Container metrics unavailable.')
        else if (d != null) ...[
          el('p', [
            text(
              'Sampled: ${DateTime.fromMillisecondsSinceEpoch(((d['sampled_at'] as num) * 1000).round()).toLocal()}',
            ),
          ], classes: 'muted'),
          el('div', [
            meter(
              'CPU ${percent(d['cpu_percent'])} · ${d['cpu_cores']} cores',
              (d['cpu_percent'] as num? ?? 0) / 100,
            ),
            meter(
              'Memory ${bytes(d['memory_used'])} / ${bytes(d['memory_total'])}',
              ratio(d['memory_used'], d['memory_total']),
            ),
            meter(
              'Swap ${bytes(d['swap_used'])} / ${bytes(d['swap_total'])}',
              ratio(d['swap_used'], d['swap_total']),
            ),
          ], classes: 'summary-grid'),
          if ((d['memory_total'] as num) > 0 &&
              (d['memory_used'] as num) / (d['memory_total'] as num) >= .9)
            notice(
              'High memory usage — avoid launching more agents.',
              error: true,
            ),
          el('details', [
            el('summary', [text('Processes by memory usage')]),
            el('p', [
              text(
                'Top 20 · process CPU uses 100% per core · RSS may include shared memory',
              ),
            ]),
            table(
              ['Process', 'PID', 'Memory', 'CPU'],
              [
                for (final p in (d['processes'] as List? ?? []))
                  [
                    text(p['name']),
                    text(p['pid']),
                    text(bytes(p['memory_bytes'])),
                    text(percent(p['cpu_percent'])),
                  ],
              ],
            ),
          ]),
        ],
      ],
      actions: [button('Refresh resources', refresh, disabled: loading)],
    );
  }
}

class CloneProjectCard extends StatefulComponent {
  const CloneProjectCard({required this.onCloned, super.key});
  final void Function(String) onCloned;
  @override
  State<CloneProjectCard> createState() => _CloneProjectCardState();
}

class _CloneProjectCardState extends State<CloneProjectCard> {
  String url = '';
  String folder = '';
  bool busy = false;
  Timer? timer;
  List<Map<String, dynamic>> jobs = [];
  String? completed;
  bool polling = false;
  String? result;
  @override
  void initState() {
    super.initState();
    refreshJobs();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refreshJobs());
  }

  Future<void> refreshJobs() async {
    final connection = dashboardConnection;
    if (polling || !connection.state.connected) return;
    polling = true;
    final epoch = connection.generation;
    try {
      final data = await connection.request('projects/jobs');
      if (!mounted || epoch != connection.generation) return;
      final next = List<Map<String, dynamic>>.from(data['jobs'] ?? []);
      if (jsonEncode(next) != jsonEncode(jobs)) setState(() => jobs = next);
      final latest = jobs.firstOrNull;
      if (latest?['state'] == 'completed' && latest?['id'] != completed) {
        completed = latest!['id'] as String;
        component.onCloned(latest['cwd'] as String);
      }
    } catch (exception) {
      if (mounted && epoch == connection.generation)
        setState(
          () => result =
              'Clone status unavailable; the server job may still be running. $exception',
        );
    } finally {
      polling = false;
    }
  }

  Future<void> clone() async {
    final connection = dashboardConnection;
    final epoch = connection.generation;
    setState(() {
      busy = true;
      result = null;
    });
    try {
      final data = await connection.request('projects/clone', {
        'url': url.trim(),
        'folder': folder.trim(),
      });
      if (!mounted || epoch != connection.generation) return;
      setState(() {
        jobs.insert(0, Map<String, dynamic>.from(data));
        result =
            'Clone queued. You can navigate away and return to see its status.';
      });
      await refreshJobs();
    } catch (error) {
      if (mounted && epoch == connection.generation)
        setState(() => result = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => el('section', [
    el('h3', [text('Clone a project')]),
    el('p', [
      text(
        'Clone a repository into a new folder inside the container’s projects directory. Existing folders are preserved.',
      ),
    ]),
    el(
      'form',
      [
        field('Repository URL', url, (value) => url = value, required: true),
        field(
          'New folder name',
          folder,
          (value) => folder = value,
          required: true,
        ),
        dom.button(
          [text('Clone project')],
          type: dom.ButtonType.submit,
          disabled: busy,
          classes: 'btn btn--primary',
        ),
      ],
      events: {
        'submit': (event) {
          event.preventDefault();
          if (!busy) clone();
        },
      },
    ),
    for (final job in jobs)
      el('div', [
        el('strong', [text(job['folder'] ?? job['url'])]),
        badge('${job['state']}', tone: toneFor('${job['state']}')),
        text(job['detail'] ?? job['cwd'] ?? ''),
        if (job['state'] == 'completed')
          button('Use project', () => component.onCloned(job['cwd'] as String)),
      ], classes: 'job-row'),
    if (result != null) notice(result),
  ], classes: 'page-stack');
}
