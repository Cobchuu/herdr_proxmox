import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart' as dom;
import 'package:web/web.dart' as web;

@JS('Terminal')
extension type _Xterm._(JSObject _) implements JSObject {
  external factory _Xterm(JSObject options);
  external void open(web.HTMLElement element);
  external void write(JSString data, [JSFunction? callback]);
  external void clear();
  external void reset();
  external void resize(JSNumber cols, JSNumber rows);
  external void focus();
  external void dispose();
  external JSObject onData(JSFunction listener);
  external JSObject onResize(JSFunction listener);
  external JSObject get buffer;
  external JSNumber get cols;
  external JSNumber get rows;
  external web.HTMLElement? get element;
}

/// Resolves a design token as the dark scheme renders it, so the terminal
/// matches the dark terminal panel in both themes. The fallback applies when
/// the token stylesheet is not loaded (unit tests).
String _darkToken(String name, String fallback) {
  final body = web.document.body;
  if (body == null) return fallback;
  final probe = web.document.createElement('span') as web.HTMLElement;
  probe.style
    ..setProperty('display', 'none')
    ..setProperty('color-scheme', 'dark')
    ..setProperty('color', 'var($name, $fallback)');
  body.append(probe);
  final value = web.window.getComputedStyle(probe).color;
  probe.remove();
  return value.isEmpty ? fallback : value;
}

/// The locally bundled xterm.js core renders terminal rows as DOM elements.
/// No canvas or WebGL addon is loaded. VT state, alternate buffers, selection,
/// paste and keyboard input are handled by the same terminal emulator.
class BrowserTerminal {
  BrowserTerminal({int maxLines = 2000}) {
    _term = _Xterm(
      {
            'scrollback': maxLines,
            'cols': 80,
            'rows': 24,
            'fontFamily':
                '"JetBrains Mono", ui-monospace, SFMono-Regular, Consolas, monospace',
            'fontSize': 13,
            'lineHeight': 1.35,
            'cursorBlink': true,
            'screenReaderMode': true,
            'theme': {
              'background': _darkToken('--color-surface-sunken', '#101414'),
              'foreground': _darkToken('--color-text', '#dce6e2'),
              'cursor': _darkToken('--color-accent', '#dce6e2'),
            },
          }.jsify()
          as JSObject,
    );
    _term.onData(((JSString value) => onOutput?.call(value.toDart)).toJS);
    _term.onResize(
      ((JSObject size) {
        onResize?.call(
          (size.getProperty<JSNumber>('cols'.toJS)).toDartInt,
          (size.getProperty<JSNumber>('rows'.toJS)).toDartInt,
        );
      }).toJS,
    );
  }
  late final _Xterm _term;
  void Function(String)? onOutput;
  void Function(int cols, int rows)? onResize;
  void Function()? onChange;
  bool _disposed = false;
  int get viewWidth => _term.cols.toDartInt;
  int get viewHeight => _term.rows.toDartInt;
  void write(String value) {
    if (_disposed) return;
    _term.write(value.toJS, (() => onChange?.call()).toJS);
  }

  void clear() {
    if (!_disposed) _term.reset();
  }

  void focus() {
    if (!_disposed) _term.focus();
  }

  void resize(int cols, int rows) {
    if (!_disposed)
      _term.resize(cols.clamp(10, 400).toJS, rows.clamp(5, 150).toJS);
  }

  String getText() {
    if (_disposed) return '';
    final active = _term.buffer.getProperty<JSObject>('active'.toJS);
    final length = active.getProperty<JSNumber>('length'.toJS).toDartInt;
    final lines = <String>[];
    for (var i = 0; i < length; i++) {
      final line = active.callMethod<JSObject?>('getLine'.toJS, i.toJS);
      if (line == null) continue;
      final value = line
          .callMethod<JSString>('translateToString'.toJS, true.toJS)
          .toDart;
      final wrapped = line.getProperty<JSBoolean>('isWrapped'.toJS).toDart;
      if (wrapped && lines.isNotEmpty) {
        lines[lines.length - 1] += value;
      } else {
        lines.add(value);
      }
    }
    return lines.join('\n').trimRight();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onOutput = null;
    onResize = null;
    onChange = null;
    _term.dispose();
  }
}

class TerminalView extends StatefulComponent {
  const TerminalView(
    this.terminal, {
    super.key,
    this.height = 400,
    this.autofocus = true,
  });
  final BrowserTerminal terminal;
  final int height;
  final bool autofocus;
  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  static int nextId = 0;
  late final String id = 'dom-terminal-${nextId++}';
  web.ResizeObserver? observer;
  Timer? mounting;
  bool opened = false;
  @override
  void initState() {
    super.initState();
    // The host must be attached before xterm can measure DOM text cells.
    mounting = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final host = web.document.getElementById(id) as web.HTMLElement?;
      if (!mounted || host == null || opened) return;
      opened = true;
      mounting?.cancel();
      final existing = component.terminal._term.element;
      if (existing == null) {
        component.terminal._term.open(host);
      } else {
        // Closing and reopening a CLI setup uses the same emulator instance.
        // Reparent its DOM rather than calling open twice and losing handlers.
        host.appendChild(existing);
      }
      observer = web.ResizeObserver(
        ((JSArray<web.ResizeObserverEntry> _, web.ResizeObserver __) => fit(
          host,
        )).toJS,
      );
      observer!.observe(host);
      fit(host);
      if (component.autofocus) component.terminal.focus();
    });
  }

  void fit(web.HTMLElement host) {
    final row = host.querySelector('.xterm-rows > div') as web.HTMLElement?;
    final sample =
        host.querySelector('.xterm-char-measure-element') as web.HTMLElement?;
    // xterm measures a run of repeated characters; one cell is that width
    // divided by the run length.
    final run = (sample?.textContent ?? '').length;
    final width =
        (sample?.getBoundingClientRect().width ?? 0) / (run > 0 ? run : 1);
    final height = row?.getBoundingClientRect().height ?? 0;
    if (width <= 0 || height <= 0 || host.clientWidth <= 0) return;
    component.terminal.resize(
      ((host.clientWidth - 22) / width).floor(),
      ((host.clientHeight - 16) / height).floor(),
    );
  }

  @override
  void dispose() {
    mounting?.cancel();
    observer?.disconnect();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => dom.div(
    id: id,
    classes: 'terminal-host',
    attributes: {
      'style': 'height:${component.height}px;padding:8px;overflow:hidden',
      'aria-label': 'Interactive terminal',
    },
    [],
  );
}
