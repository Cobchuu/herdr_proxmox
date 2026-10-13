# Juice DOM framework adapter

This private package adapts the bloc runtime from Juice **1.10.0** for a
client-only Jaspr build. The existing Flutter dashboard continues to resolve the
published Juice package. Only `web/jaspr_dashboard` overrides it with this package.

The upstream bloc, use-case, concurrency, lifecycle, status-emission and logging
implementations are retained. Flutter foundation imports resolve to the small
DOM notifier/annotation adapter. The Flutter async/selector widgets and
`JuiceWidgetSupport` are omitted. The unused widget key in `denyRebuild` accepts
`Object?`; its filtering algorithm is unchanged. Logger and rebuild-group exports
remain available. The source retains the upstream MIT license.

The DOM `ValueNotifier` must be covered by adapter tests and by the shared bloc
contract tests. Further framework changes require parity checks. This is not a
general replacement for every Juice Flutter widget or extension.
