# Development toolchain and missing tools

## Who provides which tool

There are two separate toolchains, and the product only owns one of them.

1. **The project's own pinned build toolchain** — Flutter 3.44.8 and its bundled Dart SDK, installed
   by the root-run `install/dev-tools-install.sh`. The Flutter files are owned
   by `herdr` and symlinked into
   `/home/herdr/.local/bin`. The dashboard's SDK service requests it because
   `scripts/build-web.sh` cannot produce the dashboard without it. The dashboard
   detects the configured executable file; that establishes presence, not its
   actual version or usability. Installation and builds verify the required pin.
2. **A tool one task happens to need** — a linter, a code generator, a
   language-specific checker. The worker obtains it within task permissions,
   in a task-specific cache or environment. Pin the repository-required version
   and verify release checksums or package-manager integrity, then report it.

Adding a task-specific tool to the root SDK service is not a small change. If it
also becomes a required check in `scripts/build-web.sh`, a provisioned toolchain
turns into a precondition for every integration event and every dashboard build,
because `validation.py` runs the repository's own scripts to verify each worker
merge. Task tools therefore stay out of the catalog and are installed by the
agent itself.

## The catalog

`install/toolchains.json` is the release's list of provisionable toolchains. It
ships with the release, is root-owned, and is the only place a toolchain's
installer is named:

```json
{ "flutter": { "label": "Flutter",
               "version_source": { "file": ".fvmrc", "key": "flutter" },
               "install_root": "/home/herdr/.local/share/flutter-{version}",
               "executable": "/home/herdr/.local/share/flutter-{version}/bin/flutter",
               "companion": "/home/herdr/.local/share/flutter-{version}/bin/dart",
               "script": "install/dev-tools-install.sh" } }
```

- **The catalog carries no version.** `version_source` names the file the
  repository already maintains — `.fvmrc` here — and the catalog substitutes
  whatever it declares into `install_root`, `executable` and `companion`. A
  version copied into this file would be a second pin to keep in step, and the
  project would silently build against whichever copy was forgotten.
- The install root is versioned, so an SDK of another version on disk reads as
  absent rather than present.
- `script` is relative to the release root. The root worker refuses an absolute
  path, a `..` traversal, or a symlink, so a name can never become arbitrary
  root execution. A request still accepts no installer options, and it cannot
  supply a version: the worker reads the declaration itself.
- After installing, the worker probes the installed executable and fails if it
  reports anything other than the declared version. An installation that
  succeeds while producing the wrong SDK is a failure, not a completion.
- Adding a toolchain requires a catalog entry, an installer and a version probe
  appropriate to that SDK. The current installation probe supports Flutter.
  The gateway rejects malformed catalog entries together and reports a catalog
  error; it does not hide bad entries and then guess among the remaining ones.

A request names the toolchain it wants. An older gateway sends a bare
`{'action': 'install'}`, which is accepted only while the release provisions
exactly one toolchain; with several, a nameless request is refused rather than
silently provisioning whichever sorts first. Automatic installation is refused
for the same reason, even if only one of several declared toolchains is missing.
The blocked build records the refusal once instead of stalling without explanation.

Provisioning is separate from selection, and selection is no longer a hardcoded
default: `web/gateway/toolchain_policy.py` resolves the approved policy from the
repository's own committed declarations, and that is what names the toolchain in
the build identity.

## The approved policy

`toolchain_policy.resolve_committed(checkout)` reads the committed declaration, the check scripts and
the lockfiles, and returns one canonical structure. Hashing it gives a digest that
a session, a verification run and a publication gate can all compare:

- The policy is resolved from the **approved checkout**, never from a candidate
  commit. A candidate that edits `.fvmrc`, CI, a check script or a lockfile is
  changing the rules it will be judged by, so `changes()` reports those edits for
  explicit review instead of adopting them.
- Sessions freeze the policy when work starts, recording it on the job with its
  digest and the executable paths. A later change to the declaration is then
  visible as a change to verify against rather than one that silently applies to
  work already in flight.
- The launch prompt states the rule plainly: use these tools, report a mismatch
  instead of switching SDKs, and propose an upgrade as a separate change. This is
  instruction, not enforcement — see the limit below.

## Verification evidence

Verification selects the approved SDK itself, probes the real executable, and runs
the repository's scripts with that SDK first on `PATH`. A declared
`flutter-3.44.8` cannot prove which executable ran, so the run records what it
actually measured:

- the exact candidate commit,
- the approved policy digest and any policy changes the candidate made,
- each toolchain's required version, actual version, executable path and whether
  they match,
- the required check results.

Those fields travel into the artifact manifest, the recorded result and the task,
so a delivery is authorised by evidence rather than by a label. If a probe does
not match, verification does not run at all: it records a `missing_toolchain`
blocker and refuses with what was required and what was detected.

Automatic publication then requires passing evidence for the current commit **and**
for the currently approved policy. A mismatch keeps automatic delivery pending and
records why; the automatic delivery workflow reports the blocker to its waiting
agent instead of leaving an unexplained pending delivery. A missing SDK or a provisioning failure is an
operator action; a code failure follows the existing bounded repair workflow.

## A limit worth stating

Agents share the `herdr` Unix user, and launch settings cannot guarantee which
executable every command a session runs will pick. Session prompts name the
approved executable paths. Verification puts the SDK
first on `PATH`; session launch does not yet bind the agent environment. These
settings do not confine the agent. Automatic delivery requires passing
verification under the approved toolchain. Confining execution itself needs
protected SDK installations and isolated environments per session, which is a
larger change than this one.

## The request chain

Three files, easy to confuse by name. Only one writes each file:

| Step | File | Writes or reads |
| --- | --- | --- |
| Dashboard queues a request | `web/gateway/sdk_install.py` | writes `/var/lib/herdr-sdk-requests/request.json` |
| Root worker consumes it | `install/sdk-install.py` | reads and unlinks that request, resolves the named toolchain through `install/toolchains.json`, runs its installer, and is the **only writer of `/var/lib/herdr-sdk/status.json`** |
| Gateway reports readiness | `web/gateway/sdk_install.py` | reads `status.json`, the release catalog, and each toolchain's probe |

An agent never runs these installers. An administrator can request provisioning
or opt into the existing automatic SDK policy; the root worker executes it.

In the dashboard, provisioning lives under **Herdr build tools**, next to the
other host-environment cards on the CLI accounts page (`/configuration`). It is
scoped and labelled as Herdr's own build requirements because it concerns
building Herdr itself from source, not any one repository. That label matters:
a project may be written in any language, and a card titled after "development
toolchains" reads as a statement about the project the operator has open.
The card refreshes every five seconds while installation is queued or running,
and periodically while idle. **Refresh toolchain status** requests an immediate
update. Failed requests remain visible after refreshing; completed installations
offer their bounded output for inspection.

## Project requirements are a separate scope

Herdr's build stack is not evidence about a managed project. A project states
its own requirement in the project explorer, on its repository root, under
**Project toolchains**: a tool name (`php`, `flutter`, `go`, …) and optionally a
version the project declares. Herdr reports what that project needs and how the
host stands against it — ready, not installed, version mismatch or unreadable —
by locating the executable and asking it for its real version.

Discovery and installation capability stay apart. A project may declare a tool
the release ships no installer for; that is reported as *this release ships no
installer for X* with the requirement still visible, and nothing is installed.
`GET /api/projects/toolchains` returns the per-project findings alongside the
release-scoped catalogue so a client cannot present one as the other.
`POST /api/projects/toolchain` (administrator) sets or clears one declaration;
an empty tool clears it.

Automatic provisioning consumes a verified identity. The Integration coordinator
keeps only the policy — whether a build blocked on `missing_toolchain` should
queue a request — and the tool it queues is the one the blocked project
declared, re-checked against the release catalog before any request is written.
A worker reports a blocker *category*, never a tool, so a build with no
declaration, or one naming a tool the release cannot provision, records a
specific reason and installs nothing. An install request must always name its
toolchain; the gateway refuses a bare request rather than inferring it.

## What an agent does with a missing tool

The worker bundle (`web/gateway/skills/herdr-worktree-integration/`) has a small
`SKILL.md` routing entry and full references for merge, tools, validation and
reporting. `.agents/skills/herdr-worktree-integration/SKILL.md` is the project
discovery entry linking to that canonical bundle, without duplicated procedures.
Integration prompts include the routing entry with absolute deployed reference
paths, so older worktrees need not contain the new project skill. Task launches
receive only the tool-reference location. Detail is loaded when needed, not
flattened into the 8,000-character chat request. CLI discovery and file access
depend on the runtime and profile permissions; report unreadable resources
rather than bypassing permissions. In short: install it yourself, pinned and
integrity-verified, inside a task-specific cache or environment; run the check for real;
report the commands, their real exit status, and the version and location you
installed. A check that could not run is `not_run`, never `passed`.

`missing_toolchain` means a required tool could not be obtained locally, including
network, architecture or version failures. Report the actual cause. Permission
denials use `missing_permissions`. The SDK service provisions only the
toolchains in the release catalog; it cannot fix arbitrary tool blockers.
Agents share the `herdr` account and home, so use task-specific
caches/environments and never overwrite shared tools.

The report path already exists: an agent's summary reaches the dashboard
through the existing integration event, so an agent-installed tool is visible
without new plumbing.

## Historical events

Provisioning a tool never rewrites history. An event that was recorded as
merged with validation pending stays pending until somebody retries validation
for it; enabling automatic provisioning does not convert an old event into a
pass and never waives a check.

Candidates that edit protected declarations, validation scripts or a protected
lockfile are blocked for explicit review. This change does not add an
in-dashboard policy-approval action: an operator must review and adopt the policy
in the approved repository before rerunning verification. Manual reviewed
publication retains its existing operator-controlled behavior.


### Project discovery access and SDK lookup

Both dashboards show **Discovered requirements** at a repository root in the
project explorer. They share discovery requests and override-failure handling.
Re-analyse bypasses the working-tree cache; source scope, revision, assessment
time and partial coverage remain visible. A rejected override save retains its
draft in the editor.

Working-tree census and manifest reads share descriptor-anchored access with the
file explorer. Every directory is opened relative to a pinned parent, symlinks
are refused, and only regular manifests are read within the byte budget. Native
access requires a Linux gateway and fails closed on unsupported platforms.
Committed discovery continues to use the pinned Git tree.

Flutter components also consult the nearest `.fvmrc` in their ancestor chain,
starting at the component directory and stopping at the repository root. This
models [FVM's ancestor lookup](https://fvm.app/documentation/guides/running-flutter)
within an explicit boundary; it does not prove a later command invokes FVM.
A nearer unreadable pin stays unresolved instead of falling back to an ancestor.
Pure Dart packages do not acquire a Flutter requirement just because an ancestor
pins Flutter. Host assessment checks selected versions as well as compatibility
ranges, across all components. Python probes include both `python3` and `python`;
an installed runtime still does not establish an undeclared project version.

.NET SDK discovery starts its `global.json` search at the component directory
unless the analyzer receives an explicit CLI lookup directory. This is a stated
lookup assumption, not proof of the cwd a later build will use. The nearest
file shadows ancestor files even if malformed or missing `sdk.version`. Reports
retain the context, effective evidence, shadowed declarations and repository-root
boundary; host configuration above that boundary is not read. `rollForward`,
`allowPrerelease` and `paths` are retained as policy. SDK selection against
installed SDKs remains unresolved rather than flattening those policies into a
range or claiming a gateway-cwd probe proves compatibility.


### Verifying project discovery on the correct host

A Windows failure at `open_project` proves that the boundary fails closed; it
does not verify Linux traversal. Do not mock `ANCHORED_ACCESS`, `O_NOFOLLOW` or
`dir_fd` to make the security tests run. The existing **Installer and gateway
checks** job runs on Ubuntu 24.04 and now checks the real native prerequisites
and discovers the full Python suite through the strict runner. Any skip fails
the job, including tests added outside the focused module list.

From a disposable Linux checkout with Python 3.11+, Git and Bash installed, run:

```sh
python3 scripts/test-project-discovery.py -v
```

The focused runner includes access races, explorer, census, requirements,
committed/working-tree analysis, constraints, .NET lookup, toolchain assessment
and the entire coordinator suite. It rejects unsupported hosts and any skipped
test. Its preflight checks the actual temporary filesystem: renaming a pinned
directory must preserve the original read, and reopening its replacement symlink
must be refused. Use native Linux storage for temporary fixtures; a Windows bind
mount can have different rename semantics. The output identifies Python, kernel,
uid, temporary storage and a scoped fingerprint of the current runner, gateway
Python, Python tests and bundled skill Markdown bytes. This fingerprint does not
cover every full-suite fixture, installer input or execution environment.
Git HEAD alone would not identify an uncommitted or staged local run.

For the complete integration gate, run:

```sh
python3 scripts/test-project-discovery.py --all
```

These checks create disposable fixtures and require neither a running gateway
nor a real Proxmox host. A deployment smoke check is separate: on a test gateway,
run the focused runner from a disposable checkout as the gateway service user,
then use the authenticated project explorer to analyse a representative checkout.
Confirm readable manifests, explicit permission failures, working-tree freshness,
and committed reports that remain unchanged after an uncommitted manifest edit.
This exercises the installed Python, service permissions and actual project
storage. It does not require enabling automation or installing any project SDK.
Do not run a deployment smoke test against a live task's checkout.
