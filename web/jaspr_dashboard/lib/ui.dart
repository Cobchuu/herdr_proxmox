import 'dart:async';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart' as dom;
import 'package:web/web.dart' as web;

export 'package:jaspr/client.dart';

Component text(Object? value) => Component.text('${value ?? ''}');
Component el(
  String tag,
  List<Component> children, {
  String? classes,
  Map<String, String>? attributes,
  Map<String, EventCallback>? events,
}) => Component.element(
  tag: tag,
  classes: classes,
  attributes: attributes,
  events: events,
  children: children,
);

Component button(
  String label,
  void Function()? onClick, {
  bool disabled = false,
  bool primary = false,
  String? classes,
}) => dom.button(
  [text(label)],
  type: dom.ButtonType.button,
  disabled: disabled || onClick == null,
  classes:
      'btn ${primary ? 'btn--primary' : 'btn--secondary'} ${classes ?? ''}',
  onClick: onClick,
);
Component card(
  String title,
  List<Component> children, {
  List<Component> actions = const [],
}) => el('section', [
  el('div', [
    el('h2', [text(title)]),
    el('div', actions, classes: 'actions'),
  ], classes: 'card__header'),
  el('div', children, classes: 'card__body'),
], classes: 'card');
Component badge(String label, {String tone = 'neutral'}) => el(
  'span',
  [text(label)],
  classes: 'status',
  attributes: {'data-tone': tone},
);
Component icon(String name) => el(
  'svg',
  [
    el('use', [], attributes: {'href': 'icons.svg#i-$name'}),
  ],
  classes: 'icon',
  attributes: {
    'aria-hidden': 'true',
    'viewBox': '0 0 24 24',
    'focusable': 'false',
  },
);
Component logo() => el(
  'svg',
  [
    el(
      'rect',
      [],
      classes: 'logomark__bg',
      attributes: {'width': '28', 'height': '28', 'rx': '8'},
    ),
    el(
      'path',
      [],
      classes: 'logomark__links',
      attributes: {'d': 'M14 14V6.5M14 14l-6.5 4.5M14 14l6.5 4.5'},
    ),
    el('g', [
      for (final point in [
        (14, 14, 2.6),
        (14, 6.5, 2.0),
        (7.5, 18.5, 2.0),
        (20.5, 18.5, 2.0),
      ])
        el(
          'circle',
          [],
          attributes: {
            'cx': '${point.$1}',
            'cy': '${point.$2}',
            'r': '${point.$3}',
          },
        ),
    ], classes: 'logomark__nodes'),
  ],
  classes: 'logomark',
  attributes: {'aria-hidden': 'true', 'viewBox': '0 0 28 28'},
);
Component field(
  String label,
  String value,
  void Function(String) onInput, {
  String? id,
  String? placeholder,
  bool password = false,
  bool required = false,
}) => _Control(
  label,
  value,
  onInput,
  id: id,
  placeholder: placeholder,
  password: password,
  isRequired: required,
);
Component textarea(
  String label,
  String value,
  void Function(String) onInput, {
  String? id,
  String? placeholder,
  bool password = false,
  bool required = false,
  int rows = 5,
}) => _Control(
  label,
  value,
  onInput,
  id: id,
  placeholder: placeholder,
  isRequired: required,
  kind: 'textarea',
  rows: rows,
);
Component select(
  String label,
  String value,
  Map<String, String> options,
  void Function(String) onChange,
) => _Control(label, value, onChange, kind: 'select', options: options);

class _Control extends StatefulComponent {
  const _Control(
    this.label,
    this.value,
    this.change, {
    this.id,
    this.placeholder,
    this.password = false,
    this.isRequired = false,
    this.kind = 'input',
    this.rows = 5,
    this.options = const {},
  });
  final String label, value, kind;
  final String? id, placeholder;
  final bool password, isRequired;
  final int rows;
  final Map<String, String> options;
  final void Function(String) change;
  @override
  State<_Control> createState() => _ControlState();
}

class _ControlState extends State<_Control> {
  static int nextId = 0;
  late final String generatedId = 'herdr-control-${nextId++}';
  String get id => component.id ?? generatedId;
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(syncValue);
  }

  @override
  void didUpdateComponent(_Control old) {
    super.didUpdateComponent(old);
    if (old.value != component.value || old.kind != component.kind)
      scheduleMicrotask(syncValue);
  }

  void syncValue() {
    if (!mounted) return;
    final node = web.document.getElementById(id);
    if (node == null) return;
    // Native inputs have a dirty live value independent of their HTML attribute.
    // Keep programmatic clears/provider changes in sync without moving the caret
    // when the user is simply typing the same value already in the DOM.
    if (component.kind == 'textarea') {
      final control = node as web.HTMLTextAreaElement;
      if (control.value != component.value) control.value = component.value;
    } else if (component.kind == 'select') {
      final control = node as web.HTMLSelectElement;
      if (control.value != component.value) control.value = component.value;
    } else {
      final control = node as web.HTMLInputElement;
      if (control.value != component.value) control.value = component.value;
    }
  }

  @override
  Component build(BuildContext context) => el('label', [
    el('span', [text(component.label)]),
    if (component.kind == 'textarea')
      dom.textarea(
        [text(component.value)],
        id: id,
        onInput: component.change,
        attributes: {
          'rows': '${component.rows}',
          if (component.isRequired) 'required': '',
          if (component.placeholder != null)
            'placeholder': component.placeholder!,
        },
      )
    else if (component.kind == 'select')
      el(
        'select',
        [
          for (final entry in component.options.entries)
            el(
              'option',
              [text(entry.value)],
              attributes: {
                'value': entry.key,
                if (entry.key == component.value) 'selected': '',
              },
            ),
        ],
        attributes: {'id': id},
        events: {
          'change': (event) =>
              component.change((event.target as web.HTMLSelectElement).value),
        },
      )
    else
      dom.input<String>(
        id: id,
        value: component.value,
        type: component.password ? dom.InputType.password : dom.InputType.text,
        onInput: component.change,
        attributes: {
          if (component.isRequired) 'required': '',
          'autocomplete': component.password ? 'current-password' : 'off',
          if (component.placeholder != null)
            'placeholder': component.placeholder!,
        },
      ),
  ], classes: 'field');
}

Component notice(Object? message, {bool error = false}) => el(
  'div',
  [text(message)],
  classes: error ? 'notice notice--danger' : 'notice',
  attributes: {'role': error ? 'alert' : 'status'},
);
Component table(List<String> headings, List<List<Component>> rows) =>
    el('div', [
      el('table', [
        el('thead', [
          el('tr', [
            for (final heading in headings)
              el('th', [text(heading)], attributes: {'scope': 'col'}),
          ]),
        ]),
        el('tbody', [
          for (final row in rows)
            el('tr', [
              for (final value in row) el('td', [value]),
            ]),
        ]),
      ]),
    ], classes: 'table-scroll');

final dialogChanges = ValueNotifier<int>(0);
final _dialogs = <_Dialog>[];
final messages = ValueNotifier<String?>(null);
void toast(String message) => messages.value = message;
void refreshDialogs() => dialogChanges.value++;
void closeDialogs() {
  for (final dialog in _dialogs.reversed.toList()) {
    dialog.close();
  }
}

class _Dialog {
  _Dialog(this.title, this.content, this.close, this.dismissible);
  final String title;
  final Component Function() content;
  final void Function() close;
  final bool dismissible;
}

Future<T?> showDialog<T>(
  String title,
  Component Function(void Function(T?) close) content, {
  bool dismissible = true,
}) {
  final result = Completer<T?>();
  final previouslyFocused = web.document.activeElement;
  late _Dialog dialog;
  void close(T? value) {
    if (result.isCompleted) return;
    _dialogs.remove(dialog);
    result.complete(value);
    refreshDialogs();
    scheduleMicrotask(() {
      if (previouslyFocused?.isConnected ?? false)
        (previouslyFocused as web.HTMLElement).focus();
    });
  }

  dialog = _Dialog(title, () => content(close), () => close(null), dismissible);
  _dialogs.add(dialog);
  refreshDialogs();
  scheduleMicrotask(() {
    (web.document.querySelector('.dialog-layer:last-child .dialog')
            as web.HTMLElement?)
        ?.focus();
  });
  return result.future;
}

Future<bool> confirm(
  String title,
  String message, {
  String confirmLabel = 'Confirm',
}) async =>
    await showDialog<bool>(
      title,
      (close) => el('div', [
        el('p', [text(message)]),
        el('div', [
          button('Cancel', () => close(false)),
          button(confirmLabel, () => close(true), primary: true),
        ], classes: 'actions'),
      ]),
    ) ==
    true;

Component buildDialogs() => el('div', [
  for (final dialog in _dialogs)
    el(
      'div',
      [
        el(
          'section',
          [
            el('div', [
              el('h2', [text(dialog.title)]),
              if (dialog.dismissible) button('Close', dialog.close),
            ], classes: 'dialog__header'),
            dialog.content(),
          ],
          classes: 'dialog',
          attributes: {
            'role': 'dialog',
            'aria-modal': '${_dialogs.last == dialog}',
            'aria-label': dialog.title,
            'tabindex': '-1',
            if (_dialogs.last != dialog) 'inert': '',
          },
        ),
      ],
      classes: 'dialog-layer',
      events: {
        'keydown': (event) {
          final key = event as web.KeyboardEvent;
          if (_dialogs.isEmpty || _dialogs.last != dialog) return;
          key.stopPropagation();
          if (key.key == 'Escape' && dialog.dismissible) {
            key.preventDefault();
            dialog.close();
          }
          if (key.key == 'Tab') {
            final elements = web.document.querySelectorAll(
              '.dialog-layer:last-child button:not([disabled]), .dialog-layer:last-child input, .dialog-layer:last-child select, .dialog-layer:last-child textarea, .dialog-layer:last-child a[href]',
            );
            if (elements.length == 0) return;
            final first = elements.item(0) as web.HTMLElement;
            final last = elements.item(elements.length - 1) as web.HTMLElement;
            final panel = web.document.querySelector(
              '.dialog-layer:last-child .dialog',
            );
            if (web.document.activeElement == panel ||
                !(panel?.contains(web.document.activeElement) ?? false)) {
              key.preventDefault();
              if (key.shiftKey)
                last.focus();
              else
                first.focus();
            } else if (key.shiftKey && web.document.activeElement == first) {
              key.preventDefault();
              last.focus();
            } else if (!key.shiftKey && web.document.activeElement == last) {
              key.preventDefault();
              first.focus();
            }
          }
        },
      },
    ),
]);
