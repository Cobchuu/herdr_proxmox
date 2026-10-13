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

In the dashboard, provisioning lives on the **Settings** page under
"Development toolchains", next to the other host-environment cards, because it
concerns the container rather than any one repository. The Integration
coordinator keeps only the automatic-installation policy: whether a build
blocked on `missing_toolchain` should queue a request.
The card refreshes every five seconds while installation is queued or running,
and periodically while idle. **Refresh toolchain status** requests an immediate
update. Failed requests remain visible after refreshing; completed installations
offer their bounded output for inspection.

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
