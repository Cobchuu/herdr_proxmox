@TestOn('browser')
library;

import 'dart:convert';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:web/web.dart' as web;
import 'package:herdr_jaspr_dashboard/ui.dart' as ui;
import 'package:herdr_jaspr_dashboard/services.dart';
import 'package:herdr_jaspr_dashboard/app.dart';
import 'package:herdr_jaspr_dashboard/navigation.dart';
import 'package:herdr_jaspr_dashboard/pages/native_task_ui.dart' as native;
import 'package:herdr_jaspr_dashboard/pages/organization_page.dart';
import 'package:herdr_jaspr_dashboard/pages/task_workflow.dart';
import 'package:herdr_jaspr_dashboard/pages/task_list.dart';
import 'package:herdr_jaspr_dashboard/pages/task_state.dart';
import 'package:herdr_jaspr_dashboard/pages/task_activity.dart';

class Host extends ui.StatefulComponent {
  const Host(this.child);
  final ui.Component child;
  @override
  ui.State<Host> createState() => HostState();
}

class HostState extends ui.State<Host> {
  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ui.dialogChanges.addListener(changed);
  }

  @override
  void dispose() {
    ui.dialogChanges.removeListener(changed);
    super.dispose();
  }

  @override
  ui.Component build(ui.BuildContext context) =>
      ui.el('div', [component.child, ui.buildDialogs()]);
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late ui.ClientAppBinding binding;
  DashboardBloc? connection;
  Completer<http.Response>? pendingReadiness;
  late Completer<void> requestedReadiness;
  bool failReadiness = false;
  bool failExport = false;
  final org = {
    'id': 'org',
    'name': 'Engineering',
    'purpose': 'Build tools',
    'instructions': '',
  };
  Map<String, dynamic> snapshot() => {
    'organizations': [org],
    'profiles': [],
    'groups': [],
    'jobs': [],
  };
  final oldHash = web.window.location.hash;
  setUpAll(() {
    JuiceLoggerConfig.minLevel = Level.off;
    web.document.body!.appendChild(
      web.HTMLDivElement()..id = 'review-regressions',
    );
    binding = ui.ClientAppBinding();
  });
  setUp(() {
    pendingReadiness = null;
    failReadiness = false;
    failExport = false;
    requestedReadiness = Completer<void>();
  });
  tearDown(() async {
    ui.closeDialogs();
    await settle();
    binding.detachRootComponent();
    web.document.getElementById('review-regressions')!.textContent = '';
    if (connection != null) await connection!.disconnect();
    connection = null;
    await BlocScope.reset();
    web.window.history.replaceState(null, '', oldHash.isEmpty ? '#' : oldHash);
  });
  Future<void> connect() async {
    connection = DashboardBloc(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/organizations/export') && failExport) {
          return http.Response('{"error":"Export service offline"}', 503);
        }
        if (path.endsWith('/cli-setup')) {
          if (!requestedReadiness.isCompleted) requestedReadiness.complete();
          if (pendingReadiness != null) return pendingReadiness!.future;
          if (failReadiness)
            return http.Response('{"error":"Readiness service offline"}', 503);
          return http.Response(
            jsonEncode({
              'clis': [
                {'id': 'codex', 'name': 'Codex', 'ready': null},
              ],
            }),
            200,
          );
        }
        final value =
            path.endsWith('/organizations/state') ||
                path.endsWith('/organizations/activity') ||
                path.endsWith('/organizations/directory')
            ? snapshot()
            : path.endsWith('/organizations/automation')
            ? {
                'policy': {
                  'auto_validate': true,
                  'daily_cap': 5,
                  'updated_by': 'metadata-admin',
                  'updated_at': 'metadata-timestamp',
                  'auto_queue_since': 'metadata-cutoff',
                },
              }
            : path.endsWith('/models')
            ? {'runtimes': {}}
            : path.endsWith('/session')
            ? {
                'authenticated': true,
                'operator': {'role': 'admin'},
              }
            : {'workspaces': [], 'agents': []};
        return http.Response(jsonEncode(value), 200);
      }),
    );
    BlocScope.register<DashboardBloc>(() => connection!);
    connection!.connect('test');
    await settle();
    connection!.operator.value = {'role': 'admin'};
  }

  void mount(ui.Component child) =>
      binding.attachRootComponent(Host(child), attachTo: '#review-regressions');
  web.HTMLButtonElement button(String text) {
    final buttons = web.document.querySelectorAll('#review-regressions button');
    for (var i = 0; i < buttons.length; i++) {
      final button = buttons.item(i) as web.HTMLButtonElement;
      if (button.textContent == text) return button;
    }
    throw StateError('Missing button: $text');
  }

  test(
    'organization routes select their tabs and accept the legacy alias',
    () async {
      await connect();
      for (final view in ['automation', 'runs']) {
        navigate(native.OrganizationRoute(view).path, replace: true);
        expect(currentRoute.queryParameters['view'], view);
        binding.attachRootComponent(
          const DashboardApp(),
          attachTo: '#review-regressions',
        );
        await settle();
        await settle();
        final selected = web.document.querySelector(
          '#review-regressions [role=tab][aria-selected=true]',
        );
        expect(
          selected?.textContent,
          contains(view == 'runs' ? 'Runs' : 'Automation'),
        );
        if (view == 'automation') {
          final body = web.document
              .getElementById('review-regressions')!
              .textContent!;
          expect(body, isNot(contains('metadata-admin')));
          expect(body, isNot(contains('metadata-timestamp')));
          expect(body, isNot(contains('metadata-cutoff')));
        }
        binding.detachRootComponent();
      }
      navigate('/organization?section=automation', replace: true);
      binding.attachRootComponent(
        const DashboardApp(),
        attachTo: '#review-regressions',
      );
      await settle();
      await settle();
      expect(
        web.document
            .querySelector('#review-regressions [role=tab][aria-selected=true]')
            ?.textContent,
        contains('Automation'),
      );
    },
  );
  test(
    'runtime failure shows a request error and the hire action retries it',
    () async {
      await connect();
      failReadiness = true;
      mount(const OrganizationPage(initialView: 'team'));
      await settle();
      button('Hire an agent').click();
      await settle();
      expect(
        web.document.querySelector('#review-regressions [role=dialog]'),
        isNull,
      );
      expect(
        web.document.getElementById('review-regressions')!.textContent,
        contains('Readiness service offline'),
      );
      expect(
        web.document.getElementById('review-regressions')!.textContent,
        isNot(contains('No runtime is ready')),
      );
      failReadiness = false;
      button('Hire an agent').click();
      await settle();
      expect(
        web.document.getElementById('review-regressions')!.textContent,
        isNot(contains('Readiness service offline')),
      );
      expect(
        web.document.querySelector('#review-regressions [role=dialog]'),
        isNotNull,
      );
    },
  );
  test(
    'readiness retries preserve an unrelated configuration transfer error',
    () async {
      await connect();
      mount(const OrganizationPage(initialView: 'team'));
      await settle();
      failExport = true;
      button('Export configuration').click();
      await settle();
      expect(
        web.document.getElementById('review-regressions')!.textContent,
        contains('Export service offline'),
      );
      failReadiness = true;
      button('Hire an agent').click();
      await settle();
      final body = web.document.getElementById('review-regressions')!;
      expect(body.textContent, contains('Export service offline'));
      expect(body.textContent, contains('Readiness service offline'));
      failReadiness = false;
      button('Hire an agent').click();
      await settle();
      expect(body.textContent, contains('Export service offline'));
      expect(body.textContent, isNot(contains('Readiness service offline')));
    },
  );

  for (final change in ['navigation', 'disconnect']) {
    test(
      'runtime response after $change cannot open a stale hire dialog',
      () async {
        await connect();
        pendingReadiness = Completer<http.Response>();
        mount(const OrganizationPage(initialView: 'team'));
        await settle();
        button('Hire an agent').click();
        await requestedReadiness.future;
        if (change == 'navigation') {
          binding.detachRootComponent();
          mount(const ui.Component.empty());
        } else {
          await connection!.disconnect();
        }
        ui.closeDialogs();
        pendingReadiness!.complete(http.Response('{"clis":[]}', 200));
        await settle();
        expect(
          web.document.querySelector('#review-regressions [role=dialog]'),
          isNull,
        );
      },
    );
  }
  test(
    'compatibility dialog accessible name follows its visible title',
    () async {
      mount(
        native.Builder(
          builder: (context) => ui.button('Open', () {
            native.showDialog<void>(
              context: context,
              builder: (_) => const native.AlertDialog(
                title: native.Text('Publication confirmation'),
              ),
            );
          }),
        ),
      );
      await settle();
      button('Open').click();
      await settle();
      final dialog = web.document.querySelector(
        '#review-regressions [role=dialog]',
      )!;
      final title = web.document.getElementById(
        dialog.getAttribute('aria-labelledby')!,
      );
      expect(title?.textContent, 'Publication confirmation');
      expect(dialog.getAttribute('aria-label'), isNull);
    },
  );
  test(
    'custom dialog bodies retain a valid fallback when visible headings change',
    () async {
      var showHeading = false;
      late void Function(void Function()) rebuild;
      mount(
        native.Builder(
          builder: (context) => ui.button('Open custom', () {
            native.showDialog<void>(
              context: context,
              semanticLabel: 'Inspection details',
              builder: (_) => native.StatefulBuilder(
                builder: (_, setDialogState) {
                  rebuild = setDialogState;
                  return showHeading
                      ? const native.AlertDialog(
                          title: native.Text('Visible inspection title'),
                        )
                      : ui.text('Custom body without AlertDialog');
                },
              ),
            );
          }),
        ),
      );
      await settle();
      button('Open custom').click();
      await settle();
      String? name() {
        final dialog = web.document.querySelector(
          '#review-regressions [role=dialog]',
        )!;
        return web.document
            .getElementById(dialog.getAttribute('aria-labelledby')!)
            ?.textContent;
      }

      expect(name(), 'Inspection details');
      rebuild(() => showHeading = true);
      await settle();
      expect(name(), 'Visible inspection title');
      rebuild(() => showHeading = false);
      await settle();
      expect(name(), 'Inspection details');
    },
  );

  test(
    'candidate status is consistent across workflow, list order and next step',
    () async {
      final candidate = <String, dynamic>{
        'id': 'candidate',
        'title': 'Ready candidate',
        'state': 'implementing',
        'awaiting_candidate': true,
        'repository': 'repo',
        'profile_id': 'worker',
        'assigned_agent': {'name': 'Worker'},
      };
      final closed = <String, dynamic>{
        ...candidate,
        'id': 'closed',
        'title': 'Closed task',
        'state': 'closed',
      };
      mount(TaskWorkflow(tasks: [candidate], onOpenTask: (_) {}));
      await settle();
      expect(
        web.document.querySelector('[data-node=candidate]')!.textContent,
        contains('Need candidate'),
      );
      expect(taskNextStep(candidate), contains('capture it from Changes'));
      binding.detachRootComponent();
      mount(
        taskList(
          tasks: [closed, candidate],
          stateLabel: taskState,
          onOpen: (_) {},
        ),
      );
      await settle();
      final body = web.document
          .getElementById('review-regressions')!
          .textContent!;
      expect(
        body.indexOf('Ready candidate'),
        lessThan(body.indexOf('Closed task')),
      );
      expect(candidate['state'], 'implementing');
    },
  );
}
