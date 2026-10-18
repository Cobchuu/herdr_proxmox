# Agent-assisted environment preparation

Herdr keeps discovery, acquisition and activation separate. The shared
`environment_adapters.py` registry describes executable layouts, command names,
version probes, selection files, activation variables, publisher resolvers and
archive layouts. .NET and Rust retain their trusted publisher acquisition paths.
Node.js/npm is the first adapter for adopting an agent-prepared installation;
it does not advertise a trusted managed installer.

## Enable it

An administrator enables **Prepare supported project SDKs before agent launch**
and, separately, **Allow a preparation agent to install Node.js when needed** in
the organization's automation policy. Both default to off. Existing `auto_sdk`
and SDK preparation permissions do not imply assisted installation permission.

This authorizes a dedicated agent to download and execute installers and allows
Herdr to execute the submitted SDK probes. The preparation agent shares the
service account, home and credentials used by its configured CLI. Its allocation
and instructions are not a sandbox. Enable this only when that execution
authority is appropriate for the project and agent configuration.

**Approve supported project build/test recipes automatically** remains a third
permission. It selects bounded .NET/Rust build/test conventions and declared
`npm run build` / `npm run test` proposals. These commands may execute arbitrary
project code. SDK installation permission alone never selects or runs them.
No successful SDK receipt implies that dependencies were restored or checks ran.

## Launch and adoption

1. Admission records the original launch, exact starting commit, profile and
   permission revision. The project agent remains unstarted.
2. Managed capabilities use their publisher adapters. Requirements without an
   allowed activation/adoption contract remain blockers. Undeclared versions,
   conflicts and unsupported constraint syntax are not guessed by a helper.
3. For Node, Herdr allocates a dedicated directory and a separately recorded
   `environment_preparation` session using the launch's configured CLI/model.
   It sends only the frozen requirements, never the project task. Installation
   must stay in the allocated `sdk-INDEX` directories and must not change shared
   tools or shell configuration. The helper is instructed not to execute project
   code, read project instructions, delegate or publish.
4. The helper writes an atomic `result.json` naming the exact source plan and a
   per-execution token, with one result per assisted requirement. It records an
   HTTPS installation source and its actual method. These are **agent claims**;
   they are not publisher-verified provenance or proof that an installer is safe.
5. Once the exact helper is idle and its result exists, Herdr closes that owned
   pane and inspects its output. Descriptor-anchored reads refuse symlinked
   ancestors, symbolic links and special files. A bounded tree of regular files
   is copied to a fresh content-addressed SDK snapshot. The Node contract requires
   `bin/node` and working `bin/npm`; links must be materialized as relocatable
   regular files/wrappers. The budgets are 20,000 entries, 512 MiB and 40 levels.
6. The gateway independently measures Node/npm, evaluates every recorded
   declaration through the shared constraint evaluator, and rejects probes that
   modify the SDK tree. It creates a **new immutable plan**, retaining the parent
   digest, execution/policy authority, claimed provenance and measured tree hash.
7. The existing preparation worker contextually verifies the adopted SDK against
   the recorded commit. The original waiter attaches to that exact job and
   generation. Launch uses the same process environment binding and, where
   necessary, cwd-based component dispatch as managed SDKs.

Adopted bytes are rehashed before reuse, launch/validation probes and dispatched
commands. Adapter contract versions are frozen and checked. This detects drift;
it cannot prevent a process sharing the same Unix identity from modifying an SDK
after a check. It is not publisher authentication or process confinement.

## Restart, cancellation and budgets

Allocation, start, prompt delivery, observation, adoption and completion have
durable records. A delivered preparation session can be observed after a gateway
restart without another prompt. Interrupted start/prompt/adoption states require
inspection; external acceptance followed by a lost response is never replayed.
Result files are bounded to 64 KiB and must identify their exact allocation.

Permission changes, task cancellation/reassignment, profile changes and released
helpers stop continuation. Failure never falls back to unprepared project work.
The helper has a 30 minute observation deadline. An ambiguous session identity is
left for inspection rather than closed by guess.

The waiting launch and its sequential helper share one active session slot; the
helper counts as an additional daily session start. A helper that needs attention
retains its reservation until an operator releases it. Its job and pane are
recorded separately, and the parent launch exposes its preparation execution id.

## Extending and qualifying adapters

Add another adoption adapter only when its installed layout, companion commands,
activation and contextual probes are understood. Recognition alone does not
enable installation. Publisher-backed acquisition is optional and separate.
Bump the adapter contract version when execution semantics change; old prepared
bindings then require a new plan instead of silently changing behavior.

`test_environment_adoption` exercises real Linux descriptor access, independent
probes, constraints, provenance labeling, tree mutation, symlink rejection and
budgets. `test_environment_admission` covers helper permissions, real subprocess
PTYs, restart continuation, uncertain delivery, session budgets, bound launch,
native validation and publication evidence. These tests use fixture Node/npm
executables and a CLI protocol double. They do not certify a real Node installer
or model's installation choices. The release qualification also exercises the
shared managed path against a pinned real Herdr daemon and real .NET/Rust SDKs.

Python, PHP, Go and other ecosystems still need activation/adoption adapters.
Dynamic project configuration does not become executable during discovery, and
the helper cannot approve a new constraint or manifest on the project's behalf.
