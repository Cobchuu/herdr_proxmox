import 'operations_support.dart';
import '../terminal.dart';
import 'setup_links.dart';
import 'ssh_access_card.dart';
import 'toolchain_card.dart';

class CliSetupPage extends StatefulComponent {
  const CliSetupPage({super.key});
  @override
  State<CliSetupPage> createState() => _CliState();
}

class _CliState extends OperationsState<CliSetupPage> {
  late final BrowserTerminal terminal;
  List<Map<String, dynamic>> clis = [];
  Map<String, dynamic>? integrations;
  String? session, selected;
  String paste = '';
  bool running = false, polling = false;
  int cursor = 0, generation = 0;
  Timer? timer;
  Future<void> writes = Future.value();
  @override
  void initState() {
    super.initState();
    terminal = BrowserTerminal(maxLines: 2000);
    terminal.onOutput = sendInput;
    terminal.onChange = () {
      if (mounted) setState(() {});
    };
    terminal.onResize = (cols, rows) {
      if (session != null && running)
        enqueue('resize', {
          'id': session,
          'cols': cols.clamp(10, 400),
          'rows': rows.clamp(5, 150),
        });
    };
    refresh();
    timer = Timer.periodic(const Duration(milliseconds: 300), (_) => poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    generation++;
    final id = session;
    if (id != null && connection.state.connected)
      unawaited(
        connection
            .request('cli-setup/close', {'id': id})
            .catchError((_) => <String, dynamic>{}),
      );
    terminal.dispose();
    paste = '';
    super.dispose();
  }

  Future<void> refresh() async {
    if (!connection.state.connected) return;
    final epoch = connection.generation;
    try {
      final data = await connection.request('cli-setup');
      if (valid(epoch))
        setState(() {
          clis = List<Map<String, dynamic>>.from(data['clis']);
          integrations = data['integrations'] is Map
              ? Map<String, dynamic>.from(data['integrations'])
              : null;
        });
    } catch (e) {
      if (valid(epoch)) setState(() => error = '$e');
    }
  }

  void enqueue(String action, Map<String, dynamic> body) {
    final epoch = generation, connectionEpoch = connection.generation;
    writes = writes.then((_) async {
      if (!valid(connectionEpoch) || epoch != generation) return;
      try {
        await connection.request('cli-setup/$action', body);
      } catch (e) {
        if (valid(connectionEpoch) && epoch == generation)
          setState(() => error = '$e');
      }
    });
  }

  void sendInput(String value) {
    if (session != null && running && value.isNotEmpty)
      enqueue('input', {'id': session, 'data': value});
  }

  Future<void> start(String cli) async {
    if (busy || session != null) return;
    final operation = ++generation;
    await perform((epoch) async {
      final data = await connection.request('cli-setup/start', {'cli': cli});
      if (!valid(epoch) || operation != generation) {
        if (connection.state.connected && epoch == connection.generation)
          await connection.request('cli-setup/close', {'id': data['id']});
        return;
      }
      terminal.clear();
      setState(() {
        session = data['id'] as String;
        selected = cli;
        cursor = 0;
        running = true;
      });
      enqueue('resize', {
        'id': session,
        'cols': terminal.viewWidth.clamp(10, 400),
        'rows': terminal.viewHeight.clamp(5, 150),
      });
      await poll();
    });
  }

  Future<void> cliAction(String action, String cli) async {
    if (session != null) return;
    final operation = ++generation;
    await perform((epoch) async {
      final data = await connection.request('cli-setup/$action', {'cli': cli});
      if (!valid(epoch) || operation != generation) return;
      setState(
        () => message =
            '${data['detail'] ?? (action == 'verify' ? 'Account verified.' : 'Herdr integration installed.')}',
      );
      await refresh();
    });
  }

  Future<void> poll() async {
    final id = session;
    if (id == null || polling || !running) return;
    if (!connection.state.connected) {
      await stop();
      return;
    }
    final epoch = connection.generation, operation = generation;
    polling = true;
    try {
      final data = await connection.request('cli-setup/poll', {
        'id': id,
        'cursor': cursor,
      });
      if (!valid(epoch) || id != session || operation != generation) return;
      if (data['truncated'] == true)
        terminal.write('\x1b[2J\x1b[H[Earlier output expired]\r\n');
      terminal.write(data['output'] as String);
      cursor = data['cursor'] as int;
      if (data['running'] == false) {
        terminal.write('\r\n[Setup command exited: ${data['exit_code']}]\r\n');
        setState(() => running = false);
        await refresh();
      }
    } catch (e) {
      if (valid(epoch) && id == session && operation == generation)
        setState(() {
          error = '$e';
          running = false;
        });
    } finally {
      polling = false;
    }
  }

  Future<void> stop() async {
    final id = session, epoch = connection.generation;
    generation++;
    terminal.clear();
    paste = '';
    if (mounted)
      setState(() {
        session = null;
        running = false;
        selected = null;
      });
    if (id != null && valid(epoch)) {
      try {
        await connection.request('cli-setup/close', {'id': id});
      } catch (e) {
        if (valid(epoch)) setState(() => error = '$e');
      }
    }
    await refresh();
  }

  Future<void> copy(String value) async {
    final result = await copyText(value, filename: 'cli-setup.txt');
    if (mounted) setState(() => message = result);
  }

  String integrationSummary(Map summary) {
    final connected = summary['connected'] ?? 0,
        outdated = summary['outdated'] ?? 0,
        missing = summary['missing'] ?? 0;
    final tracked = connected + outdated + missing;
    if (tracked == 0) return '';
    if (connected == tracked)
      return 'Herdr integration: all $tracked installed agents are connected. They report working/blocked state and resume finished sessions.';
    final parts = <String>[];
    for (final entry in {
      'outdated_names': 'outdated',
      'missing_names': 'not installed',
    }.entries) {
      final names = (summary[entry.key] as List? ?? []).join(', ');
      if (names.isNotEmpty) parts.add('${entry.value}: $names');
    }
    return 'Herdr integration: $connected of $tracked installed agents current${parts.isEmpty ? '' : ' — ${parts.join('; ')}'}. Agents without a current integration cannot report state or resume sessions.';
  }

  Component account(Map<String, dynamic> cli) {
    final active = session != null && selected == cli['id'];
    final ready = [
      'configured',
      'credentials_detected',
    ].contains(cli['status']);
    final integration = cli['integration'] as Map?;
    return card('${cli['name']}', [
      badge(active ? 'Setup open' : '${cli['status']}'.replaceAll('_', ' ')),
      paragraph(cli['detail']),
      button(
        active
            ? 'Setup in progress'
            : cli['installed'] != true
            ? 'CLI not installed'
            : ready
            ? 'Manage account'
            : 'Connect account',
        () => start(cli['id'] as String),
        primary: true,
        disabled: busy || session != null || cli['installed'] != true,
      ),
      if (cli['id'] == 'claude' && cli['installed'] == true)
        button(
          'Test account',
          () => cliAction('verify', cli['id'] as String),
          disabled: busy || session != null,
        ),
      if (cli['installed'] == true && integration?['current'] == true)
        paragraph(
          'Herdr integration ${integration?['version'] ?? ''} — connected',
        ),
      if (cli['installed'] == true && integration?['current'] != true) ...[
        paragraph(
          integration?['installed'] == true
              ? 'Herdr integration is outdated, needs repair or could not be verified. Until current, this agent cannot report state or resume finished sessions.'
              : 'Herdr integration missing. Without it this agent cannot report state or resume finished sessions.',
        ),
        button(
          integration?['installed'] == true
              ? 'Update Herdr integration'
              : 'Install Herdr integration',
          () => cliAction('install_integration', cli['id'] as String),
          disabled: busy || session != null,
        ),
      ],
      if (session != null && !active)
        paragraph('Close the active setup to switch accounts.'),
    ]);
  }

  @override
  Component build(BuildContext context) => stack([
    card('CLI accounts', [
      paragraph(
        'Connect your coding agents to their providers. Choose an account to open its sign-in terminal.',
      ),
      button('Refresh status', refresh, disabled: busy),
      if (integrations != null && (integrations!['total'] ?? 0) > 0)
        paragraph(integrationSummary(integrations!)),
      feedback(),
    ]),
    el('div', [for (final cli in clis) account(cli)], classes: 'summary'),
    if (session != null)
      card(
        '${clis.where((c) => c['id'] == selected).firstOrNull?['name'] ?? selected} setup · ${running ? 'Active' : 'Finished'}',
        [
          actions([
            button('Ctrl+C', () => sendInput('\x03'), disabled: !running),
            button('Close terminal', stop),
            button('Copy terminal text', () => copy(terminal.getText())),
            button(
              'Select terminal text',
              () => showDialog<void>(
                'Terminal text',
                (close) => stack([
                  codeText(terminal.getText()),
                  button('Close', () => close(null)),
                ]),
              ),
            ),
          ]),
          paragraph(
            'Open the sign-in link shown below. Use the controls or click the terminal to type.',
          ),
          for (final link in setupLinks(terminal.getText()))
            actions([
              button(
                'Open link · ${link.host}',
                () => openExternal(link.toString()),
              ),
              button('Copy link', () => copy(link.toString())),
            ]),
          TerminalView(terminal, height: 340),
          actions([
            for (final key in {
              '↑ Up': '\x1b[A',
              '↓ Down': '\x1b[B',
              'Enter': '\r',
              'Tab': '\t',
              'Escape': '\x1b',
            }.entries)
              button(key.key, () => sendInput(key.value), disabled: !running),
          ]),
          field(
            'Authorization code or API key',
            paste,
            (value) => paste = value,
            password: true,
          ),
          button(
            'Send to terminal',
            () {
              sendInput('$paste\r');
              setState(() => paste = '');
            },
            primary: true,
            disabled: !running,
          ),
          paragraph(
            'Send the hidden input only when asked. The CLI controls input echo. Output stays in memory and clears when closed. Closing the page stops setup; abandoned sessions expire after 10 minutes without activity.',
          ),
        ],
      ),
    const SshAccessCard(),
    const ToolchainCard(),
  ]);
}
