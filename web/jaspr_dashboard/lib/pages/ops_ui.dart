/// Phase 2 presentation helpers for the agent console, knowledge, explorer,
/// logs and CLI account pages. Markup only: callouts, pills with a shape,
/// definition-list facts, switches, chips and the dark terminal panel.
library;

import 'package:jaspr/dom.dart' as dom;
import '../ui.dart';

/// Page wrapper: the template page header followed by stacked regions.
Component opsPage(List<Component> children, {String? classes}) =>
    el('div', children, classes: ['ops-page', ?classes].join(' '));

/// Status pill (`.status` renders as the template `.pill`) whose dot repeats
/// the state with a shape: filled, hollow, diamond or dash.
Component pill(String label, {String tone = 'neutral', String? shape}) => el(
  'span',
  [text(label)],
  classes: 'status ops-pill',
  attributes: {'data-tone': tone, 'data-shape': ?shape},
);

/// Tone for free-text gateway states (jobs, events, snapshots).
String stateTone(Object? state) {
  final value = '${state ?? ''}'.toLowerCase();
  if (value.contains('fail') ||
      value.contains('error') ||
      value.contains('blocked') ||
      value.contains('attention') ||
      value.contains('uncertain'))
    return 'danger';
  if (value.contains('pending') ||
      value.contains('deferred') ||
      value.contains('waiting') ||
      value.contains('queued'))
    return 'warning';
  if (value.contains('running') ||
      value.contains('validating') ||
      value.contains('progress'))
    return 'info';
  if (value.contains('complete') ||
      value.contains('passed') ||
      value.contains('integrated') ||
      value.contains('connected') ||
      value.contains('configured') ||
      value.contains('detected'))
    return 'success';
  return 'neutral';
}

/// Shape that repeats a tone without color (WCAG 1.4.1).
String shapeFor(String tone) => switch (tone) {
  'danger' => 'diamond',
  'neutral' => 'hollow',
  _ => 'filled',
};

/// One message with an optional title and actions (template `.callout`).
Component callout(
  List<Component> lines, {
  String tone = 'info',
  String? iconName,
  String? title,
  List<Component> actions = const [],
  String? role,
}) => el(
  'div',
  [
    icon(
      iconName ??
          switch (tone) {
            'danger' => 'triangle-alert',
            'warning' => 'clock',
            'success' => 'circle-check',
            _ => 'info',
          },
      classes: 'callout__icon',
    ),
    if (title != null) el('p', [text(title)], classes: 'callout__title'),
    ...lines,
    if (actions.isNotEmpty)
      el('div', actions, classes: 'actions callout__action'),
  ],
  classes: 'callout ops-callout',
  attributes: {'data-tone': tone, 'role': ?role},
);

Component calloutText(Object? value) =>
    el('p', [text(value)], classes: 'callout__text');

/// Definition list of facts. A visually hidden ": " keeps each pair readable
/// as one "Label: value" phrase for assistive technology and text search.
Component facts(List<(String, Component)> pairs, {String? classes}) =>
    el('dl', [
      for (final pair in pairs)
        el('div', [
          el('dt', [
            text(pair.$1),
            el('span', [text(': ')], classes: 'visually-hidden'),
          ]),
          el('dd', [pair.$2]),
        ]),
    ], classes: ['dl', 'ops-dl', ?classes].join(' '));

Component mono(Object? value) => el('span', [text(value)], classes: 'mono');

/// Template `.none`: an em dash plus hidden "None" for a missing value.
Component none() => el('span', [
  el('span', [text('—')], attributes: {'aria-hidden': 'true'}),
  el('span', [text('None')], classes: 'visually-hidden'),
], classes: 'none');

Component iconTile(String name, {String? tone, String size = ''}) => el(
  'span',
  [icon(name)],
  classes: ['icon-tile', if (size.isNotEmpty) 'icon-tile--$size'].join(' '),
  attributes: {'data-tone': ?tone, 'aria-hidden': 'true'},
);

/// Small secondary line with an optional leading icon.
Component meta(Object? value, {String? iconName, String? classes}) => el('p', [
  if (iconName != null) icon(iconName, classes: 'icon--sm'),
  text(value),
], classes: ['ops-meta', ?classes].join(' '));

/// Template switch for settings that apply immediately.
Component switchField(
  String label,
  bool checked,
  void Function(bool)? change, {
  bool disabled = false,
}) => dom.label(classes: 'switch ops-switch', [
  dom.input<bool>(
    type: dom.InputType.checkbox,
    checked: checked,
    disabled: disabled || change == null,
    onChange: change,
    classes: 'switch__input',
    attributes: {'role': 'switch'},
  ),
  dom.span(classes: 'switch__label', [Component.text(label)]),
]);

/// Single-select filter chip (template `.chip[aria-pressed]`).
Component chip(String label, bool pressed, void Function()? onClick) =>
    dom.button(
      [icon('check', classes: 'chip__check'), Component.text(label)],
      type: dom.ButtonType.button,
      classes: 'chip',
      disabled: onClick == null,
      onClick: onClick,
      attributes: {'aria-pressed': '$pressed'},
    );

/// Dark card around an xterm host: a header strip (icon, title, pills,
/// actions), the terminal body and an optional footer note.
Component terminalPanel({
  required String title,
  required List<Component> body,
  String iconName = 'terminal',
  List<Component> status = const [],
  List<Component> actions = const [],
  List<Component> footer = const [],
  String? classes,
}) => el(
  'section',
  [
    el('div', [
      el('h2', [icon(iconName), text(title)], classes: 'terminal-panel__title'),
      ...status,
      el('div', actions, classes: 'actions terminal-panel__actions'),
    ], classes: 'terminal-panel__header'),
    el('div', body, classes: 'terminal-panel__body'),
    if (footer.isNotEmpty) el('div', footer, classes: 'terminal-panel__footer'),
  ],
  classes: ['terminal-panel', ?classes].join(' '),
  attributes: {'aria-label': title},
);
