import '../ui.dart';
import '../terminal.dart';

/// A terminal inspection is a complete retained snapshot, not a websocket
/// output delta. Replace its DOM buffer only when the snapshot changes.
class SnapshotTerminal extends StatefulComponent {
  const SnapshotTerminal(this.output, {super.key, this.height = 360});
  final String output;
  final int height;
  @override
  State<SnapshotTerminal> createState() => _SnapshotTerminalState();
}

class _SnapshotTerminalState extends State<SnapshotTerminal> {
  late final BrowserTerminal terminal;
  @override
  void initState() {
    super.initState();
    terminal = BrowserTerminal();
    update();
  }

  void update() {
    terminal.replaceSnapshot(
      component.output.replaceAll(RegExp(r'(?<!\r)\n'), '\r\n'),
    );
  }

  @override
  void didUpdateComponent(SnapshotTerminal old) {
    super.didUpdateComponent(old);
    if (old.output != component.output) update();
  }

  @override
  void dispose() {
    terminal.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => TerminalView(
    terminal,
    height: component.height,
    autofocus: false,
    label: 'Retained terminal output',
  );
}
