# Native Jaspr dashboard

The entire release dashboard now renders HTML/CSS through client-only Jaspr.
There is no Flutter canvas or embedding iframe in the active application.
`web/jaspr_dashboard` replaces the old release entrypoint at both `/` and
`/dashboard/`; existing hash routes and browser back navigation remain supported.
The old Flutter sources remain available as a behavior reference and regression
suite. The obsolete iframe wrapper has been removed.

## Business behavior and framework boundary

`web/dashboard_state/lib` contains the original dashboard and organization blocs,
integration helpers and secure request-ID implementation. Their implementations
are unchanged. Existing Flutter bloc imports forward to the shared package.
The gateway and business repositories were not modified by this migration.

Juice 1.10.0 imports Flutter foundation and `dart:ui` from its core. The Jaspr
package uses the private, licensed core adapter under `vendor/juice`, retaining
its event dispatch, state, lifecycle, concurrency and use-case implementations.
The adapter replaces Flutter foundation types with browser-compatible notifier
primitives and excludes Flutter widgets. The original Flutter regression suite
continues to resolve published Juice.

Handlers previously embedded in widget state were mechanically ported with their
API payloads, admin gates, polling, generation guards, idempotency keys, inspection
steps, retry references and confirmation requirements. UI state is disposed on
route/account changes; pending dialogs close when the session generation changes.

## Completed surfaces

| Surface | Native implementation |
| --- | --- |
| Authentication and shell | Token sign-in, cookie-session restoration, expiry/sign-out, organization rail, scoped agents/groups, notices, themes, mobile drawer |
| Overview and agent activity | Workspace create/focus/rename, clone job reconciliation, filters, resource polling and observed activity |
| Organizations | Organization CRUD, team/hire/models/permissions, SVG chart, delegation, automation and import/export |
| Agent console and sessions | VT terminal, input/resize, inspection, archive/restart/continue/resume/close, released-session cleanup |
| Groups and chat | Members/settings, proposals, discussions, history, durable retries, recovery, streaming, archive/continuation |
| Tasks and discovery | Assignments, queues, execution, handovers, consultations, review/repair/acceptance, delivery, automation, publication, PR evidence and proposal actions |
| Task timeline | SVG commit graph, commit selection and exact-commit build evidence |
| Knowledge | Organization scope, search, filters, pagination, creation/review/superseding, provenance and source navigation |
| Explorer and Git | Browse/preview/download, worktrees, diffs, inspected base updates and recovery safeguards |
| Builds and integration | Exact-commit evidence, logs/artifacts/manifests, deployment/provenance/rollback approvals, coordination and selected blocker waivers |
| Logs and CLI accounts | Saved/live logs, capture/download/delete, provider setup, verification, DOM terminals and route cleanup |
| Settings | SSH keys, dashboard access, SDK installs, stable/alpha updates and tunnel acknowledgement |

## Jaspr settings and Phase 2 design

The dashboard pins Jaspr **0.23.5** and declares `jaspr: mode: client`, matching
`flutter_evidence/spa`. Its browser entrypoint imports `package:jaspr/client.dart`,
initializes Jaspr and mounts `DashboardApp` into the body. Client mode is appropriate
for this authenticated, interactive dashboard; the gateway continues to serve
static assets and APIs. See the official [client rendering documentation](https://docs.jaspr.site/dev/client).

The direct `dart compile js -O2` build is intentional. This application has no
`@client` islands, generated styles, server rendering or hydration options, so
it does not require the Jaspr CLI/generator pipeline. Introducing those features
would require generated options and the corresponding build dependencies.

Phase 2 supplies the theme tokens, Lucide icon sprite, organization rail/sidebar,
card treatments, indigo controls, status colors and responsive layout. It is applied
to every page: `css/tokens.css` (light/dark tokens), `styles.css` (base, app shell,
element defaults), `css/components.css` and `css/composites.css` (the template's
shared components), then one stylesheet per page area (overview, org chart and
organization, task workflow, builds, remaining pages). The shell has a collapsible
sidebar (`herdr.sidebar`), a topbar runtime pill and theme switcher instead of a
status bar, and `ui.dart` provides the shared page header, card, pill, role tile,
empty state and stacked bar helpers. The required
assets live under `web/`; the extracted design reference has been removed. The
zip's text and demo JavaScript were not treated as task instructions or application
business behavior. Release assets include
only the selected CSS/icons and the locally bundled, licensed xterm.js **5.5.0**
DOM renderer. No Canvas/WebGL terminal addon is included.

## Build and verification

- `scripts/build-web.sh` / `scripts/build-web.ps1`: validate the pinned toolchain,
  resolve shared-package dependencies, analyze/test the preserved Flutter contracts, then analyze/test/compile Jaspr
  and package all styles, SVG and terminal assets at both established URLs.
  Only compiled JavaScript and static assets are packaged; Dart entrypoint source
  stays in its package. After this setup, `dart analyze` also works from the
  repository root. Generated build/deployment directories are excluded from analysis.
- `scripts/build-jaspr-dashboard.sh`: build the same native UI for local preview.
- `dart test --platform chrome --concurrency=1` in `web/jaspr_dashboard`: native browser workflow
  regressions, also required by CI. These use simulated API clients.
- `python scripts/preview-jaspr.py --production`: inspect packaged assets using
  real browser-session handlers and disposable organization storage on loopback
  port 8793. Use the printed demo token. Operational actions are simulated;
  do not enter real provider credentials into this preview.

Verified locally: preserved Flutter suite **188 tests**, Jaspr VM suite **10 tests**,
Chrome workflow suites (**56 tests**, run serially for shared browser focus), clean analyzers, optimized compilation, production asset
packaging, version-guard mock build, and unchanged shared implementation contents.
Browser inspection includes desktop/mobile layouts and zero iframe/canvas elements.
The browser suites cover permissions, inspection/approval gates, stale accounts,
exact build identities, durable retry IDs, dialogs, controlled native fields,
terminal resize/output retention and queued-input cleanup.

No release publication or live Proxmox deployment is part of these local changes.
A live-host smoke test remains a deployment check, especially for real provider
terminals, container networking, toolchain installation and release promotion.

## UI regression verification

The native UI uses one page scroll surface; disclosure accessibility text is
contained, and bounded evidence/terminal panels and dialogs retain their own
intentional scrolling. Verified runtime ownership drives the original activity
palette: idle/done green, working blue, and attention amber.

Group terminals render retained output independently from optional errors,
including healthy `error: ""` responses. Their DOM emulators attach when visible,
refresh when disclosures reopen, and remain bound to each stream across polling
and reordering. Chart pan gestures work from the background, cards and names;
a completed drag does not open a console or group by accident.

The regression run passed 85 isolated Chrome tests, 10 VM tests, repository-wide
Dart analysis and optimized compilation. Browser regressions use independent
fixtures with simulated API responses, including real xterm DOM rendering.
