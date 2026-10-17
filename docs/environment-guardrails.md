# Environment guardrails: implementation plan

Status: partially implemented, updated 2026-10-17. Companion to
`docs/automatic-project-environments.md`, which defines the overall work
packages. This document covers one slice: making the resolved environment plan
the thing that constrains launch, agent work, validation and publication.

The staged runtime now connects prepared environments to the existing policy
mechanism. `EnvironmentPolicies` is installed in both the gateway and durable
build worker; `resolve_committed()` is the shared seam for session guidance,
validation and publication. It reads committed discovery and a successful SDK
preparation record. Missing bindings become blockers, not an empty policy.

Implemented and covered by gateway tests:

- `bindings(plan, receipt)` carries per-component cwd, exact SDK paths and the
  frozen plan identity. Guidance includes those paths and any blockers; legacy
  Herdr self-build wording remains unchanged.
- Validation probes the bound SDK in each candidate component before running
  explicitly administrator-selected native recipes. Each invocation gets its own
  SDK environment. Rust includes compiler and Cargo version evidence. A missing
  recipe or SDK does not produce a passing validation.
- Publication requires the approved policy/plan identities, every component's
  matching executable/version evidence and the selected check results. Candidate
  declaration, lockfile, SDK configuration and workflow changes require review.
- Both project cards let an administrator approve frozen check proposals before
  preparation. SDK preparation receipts remain SDK-only; later validation runs
  carry separate actual check evidence. Approved build/test commands may perform
  their native dependency restore; there is no standalone restore job receipt.
- Worker SDK observations can be reported in `tools` or structured `tests`
  records. Mismatches are retained and displayed as unverified claims. Review
  groups receive a bounded policy/requirement summary and no-install instructions.
- Prepared compatible SDKs are passed to a new interactive shell through Herdr's
  native `tab create --env` API before `agent start`. The execution records the
  requested environment and its plan/policy identities. No gateway credentials
  are copied. Different component selections use one cwd-aware command dispatcher
  with immutable per-execution bindings, rather than competing PATH entries.
  Trusted exports are applied after shell startup,
  with a fresh completion marker preventing agent start from racing the exports.
  Before task delivery, the foreground agent's Linux process environment is
  compared with the requested variables, with PID/start-time checks. This proves
  initial inheritance, not confinement or later SDK selection. The pinned real
  daemon has exercised this path locally with fixture SDKs; real-SDK glibc/arm64
  qualification remains the release CI prerequisite.
- Automatic admission parks the existing launch before runtime topology creation.
  A waiter freezes source/permission intent separately from the resulting bound
  policy. Planning, acquisition and contextual probes happen outside organization
  workers/transactions. Successful preparation admits only that execution.
- Graceful shutdown, expired leases and restart recover safe waits. Revoked
  permission, cancelled/reassigned tasks and changed profiles do not resume.
  Ambiguous external launch acceptance remains inspectable and is not replayed.
- Organization native-check approval is separate from SDK preparation permission;
  both start disabled. Native check proposals can restore and execute project
  code, so their approval is explicit even when the SDK can be installed safely.

Remaining: additional ecosystem adapters, broader explicit check-selection policies,
standalone dependency-restore jobs and waiting/resume for independent validation
requests. Guidance is still instruction, not
confinement. The real-SDK release qualification now exercises product validation
and the publication evidence gate, but has not run locally on a glibc executor.

The sections below retain the design rationale and acceptance requirements;
they are not a claim that these remaining pieces are complete.

## 1. Original problem, before the implementation above

The original plan addressed several sources of drift. There were three
interpretations of "what this project needs", and only one was enforced.

| Layer | Source of truth | Shape | Enforced |
| --- | --- | --- | --- |
| Discovery → plan | `project_requirements.ECOSYSTEMS` + `dependency_constraints` | per component, ranges, notation, evidence | No consumer at launch or validation |
| Task policy | `toolchain_policy.resolve_committed` reading `install/toolchains.json` `version_source` | exact pins through a release-shaped catalog | Yes — probes and blocks |
| Agent guidance | `skills/herdr-worktree-integration/references/tools.md` | prose | No — the agent re-derives from a lockfile |

The original consequences, retained as historical rationale:

- `contributions.task_instructions()` contains no tool, version or requirement.
  The prompt says only `Task-local tool acquisition policy:` followed by a path
  to prose which instructs the agent to "pin the version required by the
  repository's CI or lockfile".
- `environment_plan` is imported by `environment_preparation`,
  `environment_store`, `project_analysis.plan()` and `server.py`. Neither
  `contributions.py` nor `validation.py` reads it.
- `policy_guidance()` already tells the agent which SDK to use and to report a
  mismatch instead of installing one — but its input is the release catalog,
  which names Flutter only. A .NET project gets an empty policy and therefore no
  guidance at all.
- `validation.COMMANDS = ('scripts/validate.sh', 'scripts/build-web.sh')` is a
  constant. A .NET solution has neither, so `_commands()` finds nothing and
  validation refuses with "No validation script found" — for a project the plan
  can already name the exact SDK for.
- `toolchain_policy.DECLARATIONS` and `LOCKFILES` are fixed Herdr-oriented paths
  (`.fvmrc`, `web/dashboard/pubspec.lock`). They can match another repository's
  files, but do not cover arbitrary managed-project declarations and lockfiles.

## 2. One bottleneck, and what is already right

Four consumers share one function:

| Consumer | Call site | Uses |
| --- | --- | --- |
| Agent instruction | `organizations.frozen_policy` → `policy_guidance` | `toolchains[]`, `digest` |
| Queue identity | `validation.submit` | `name-required` pairs, `digest` |
| Run-time proof | `validation._execute` | `verify()`, `environment()`, `changes()` |
| Publication gate | `contributions.policy_matches` | `digest`, `toolchain_evidence` |

All four call `toolchain_policy.resolve_committed(path)`. That is the seam.

The mechanism around it is already correct and must not be rebuilt:

- `policy_guidance` states the expectation, names the absolute executable, carries
  the digest, and says "stop and report the mismatch rather than switching or
  installing an SDK yourself".
- `frozen_policy` freezes the policy before the agent starts and records it on
  the job, so a later declaration change is a change to verify against rather
  than something that silently applies to work in flight.
- `verify()` probes the real binary and refuses to run the build on a mismatch.
- `changes()` reports declaration/lockfile edits for review; callers decide
  whether to block. It neither applies a candidate's policy nor approves it.
- `policy_matches` ties publication to evidence produced under the approved
  digest.
- `environment_store` already persists plans by immutable digest.

So the work is not to invent a guardrail mechanism. It is to **change what that
one function reads**, and then to extend four things it cannot currently express.
This is a useful seam, not a signature-preserving drop-in replacement: contextual
probes, component identity, dynamic fingerprints and per-component environments
also require changes in its consumers.

## 3. Target design

### 3.1 Bindings derived from the plan

Add to `environment_plan.py`:

```python
def bindings(plan, preparation_receipt):
    """The approved toolchain policy, derived from the plan, in the shape every
    consumer already expects. No new interpretation is introduced."""
```

Returns the existing policy shape, extended per entry:

```python
{
  'toolchains': [
    {'name': 'dotnet-sdk', 'label': '.NET SDK', 'required': '8.0.100',
     'declared_by': 'Api/global.json#sdk.version',
     'component': 'Api', 'cwd': 'Api',
     'executables': ['/var/lib/herdr/environments/<key>/dotnet'],
     'source': 'prepared' | 'path'},
  ],
  'checks': [...],       # legacy policy currently carries a list of check paths
  'lockfiles': {...}, 'declarations': {...},
  'recipe_fingerprints': {...},  # new: approved recipe content/identity
}
```

`component` and `cwd` are new and are what the doc's per-component requirement
and contextual selection need. `executables` gains the prepared path when a
verified receipt exists. A plan alone does not contain a verified executable
binding. Join only a ready receipt with matching plan digest, revision, component,
SDK selection and artifact identity, then re-probe before use. PATH measurements
and managed activation capability remain separate facts.

Naming that executable in guidance remains an instruction. It does not bind the
agent process or confine commands; verification must select and probe it itself.

Preserve existing signatures where possible, with explicit compatibility adapters.
`verify` must receive the execution checkout and resolve each relative `cwd`
inside it. A cwd string alone cannot identify that checkout. Entries and
`changes()` must key by `(component, capability)`: the current name-only maps
would collapse two components selecting different SDK versions. Selection probes
must use the recorded executable and environment in that component's context.

### 3.2 The plan digest becomes the task's policy identity

Today a task freezes a policy dict. It should additionally reference the approved
**plan**, addressed by digest, and record that digest on the job:

- `frozen_policy` resolves the plan for the task's checkout at its committed
  revision, stores it, and returns `{'plan_digest': ..., 'bindings': ...}`.
- Validation and publication refer to that frozen approval plan; they do not
  build a new plan from a candidate and expect equal hashes. The plan includes
  the source revision, project and host observations, so a new candidate commit
  necessarily has a different execution-plan digest.
- Retain the approved policy digest and candidate commit as distinct evidence
  alongside the frozen `plan_digest`. Publication must still check that the
  approved rules remain current, not merely that an old plan exists.
- Extend the approved declaration/lockfile fingerprint set from discovery and
  recipe evidence. `changes()` compares those fingerprints, so a
  candidate that edits `global.json` or a lockfile still cannot reuse the
  approved evidence.

This is what makes "a candidate cannot redefine the rules that judge it" hold
across all four consumers with one identity.

### 3.3 Check recipes as data

Replace the `COMMANDS` constant with recipes carried by the plan. The data
already exists: `project_requirements` emits `candidate_commands` per component
with `source: 'package.json#scripts'` (repository-declared) or `'convention'`.

| Kind | Selection rule |
| --- | --- |
| Repository-declared recipe | Eligible under the approved project-script execution policy; freeze its content, arguments and cwd before running. Declaration alone does not grant execution permission. |
| Conventional recipe | A labelled proposal until an organization policy selects it (`selected_by` recorded). |
| No recipe | An explicit unresolved build plan, never an empty pass. |

`validation._commands()` then selects from the plan rather than the constant, and
the same list feeds the `checks` fingerprint so the set that runs and the set
that is tamper-checked cannot diverge — which today they can, because `COMMANDS`
and `CHECKS` are two copies of the same list.

### 3.4 Binding the environment

`toolchain_policy.environment(policy)` currently sets only `PATH`. A component
environment builder must also emit the variables its prepared SDK needs (`DOTNET_ROOT`,
`DOTNET_MULTILEVEL_LOOKUP=0`, `RUSTC`, `CARGO_HOME`) from the receipt. Validation
already passes an environment to `run_scripts`, but one merged PATH cannot
select two .NET or Rust versions for different components. Build one environment
per component/check invocation, use its recorded cwd and absolute SDK bindings,
and keep the legacy single-environment path for old policies during migration.

**Prerequisite to resolve first:** the agent launch path passes no environment.
`organizations.py:1664` invokes `herdr agent start` with CLI arguments only, and
`launch_arguments()` builds only model flags. Binding an agent's environment needs
an explicit environment capability on the agent command or a launcher that
actually starts the process with the recorded environment. A task-local wrapper
mentioned only in a prompt remains voluntary. Confirm the supported launch
interface before promising process binding; guidance naming an absolute
executable is the existing instructional fallback.

## 4. Steps

Each step is independently shippable and independently testable.

### Step 1 — Bindings from the plan

- Add `environment_plan.bindings(plan, preparation_receipt)`.
- `organizations.frozen_policy` derives from the plan for the checkout revision,
  retaining the legacy resolver only for explicitly identified legacy policies
  during migration. A recognized but unresolved or blocked project must surface
  that blocker; a blanket fallback on planning errors could silently turn .NET
  requirements into an empty Flutter-shaped policy.
- `policy_guidance` is unchanged.

Acceptance: a .NET project's launch prompt names `.NET SDK 8.0.100` and its
executable; a Flutter project's prompt is byte-identical to today's.

### Step 2 — Per-component entries and contextual verification

- `bindings()` emits one entry per (component, capability) with `cwd`.
- `toolchain_policy.verify()` probes in `cwd`; `environment()` emits tool
  variables.

Acceptance: two components selecting different SDK versions both verify; a
component whose selection is wrong blocks with `toolchain_message` naming that
component. A complete analysis establishing no SDK requirements does not add an
SDK blocker; unresolved declarations or incomplete discovery are not that case.

### Step 3 — Plan digest as policy identity

- Job records `plan_digest`; validation and `policy_matches` use it.
- Extend `changes()` for discovered fingerprints and component/capability keys.

Acceptance: a candidate governed by unchanged approved rules references the
frozen plan and policy identities; a candidate that edits `global.json` or a
lockfile is refused with the existing `toolchain_block` reason. A complete report
establishing no SDK requirements is not SDK-gated. Absence of a selected check
recipe still cannot produce a passing build.

### Step 4 — Check selection from the plan

- `validation._commands()` selects plan recipes; `COMMANDS` is retired.
- Legacy `scripts/validate.sh` remains selected for Herdr's own repository
  because the plan learns it as a repository-declared recipe.

Acceptance: a .NET solution with no `scripts/validate.sh` runs `dotnet test` on
the identified test project and records real evidence; `.NET` plus Node runs
both; a project with no recipe reports an unresolved build plan rather than
passing.

### Step 5 — Reported-version comparison

- Extend `read_receipt` to extract the tool evidence an agent reports and compare
  it to the plan's resolved versions.
- Record a discrepancy as a task finding naming required and reported, never as a
  silent pass. The receipt remains "reported claims, not verified facts"; the
  trusted signal stays `verify()` in validation.

Acceptance: an agent that installs 9.0.x while the plan requires 8.0.100 produces
a recorded finding; an agent that used the bound SDK produces none.

### Step 6 — Discussion awareness

- `repository_review_context` carries the plan digest and a bounded summary of
  resolved requirements, so a review group knows what the project needs.
- Review instructions say to use the recorded environment and not to install.

Acceptance: a repository review's baseline includes the requirements and the
digest, and reviewers are told not to install toolchains.

## 5. Migration and compatibility

- **Herdr's own build must keep working.** `scripts/validate.sh`,
  `scripts/build-web.sh` and `.fvmrc` continue to be discovered as
  repository-declared evidence, so the plan reproduces today's policy for
  Herdr's own repository. Step 4 is the one that must be proven against the
  existing self-build path.
- **`auto_sdk` and the coordinator's blocker recovery stay** until replaced. The
  plan's `acquire` state becomes their input rather than a second decision.
- **No schema change removes data.** `toolchain_policy=` on a job is superseded
  by `plan_digest` but read during migration; a job without one behaves as today.
- **The release catalog keeps provisioning Herdr.** It is release capability, and
  `install/sdk-install.py`'s authority model is unchanged by this slice.

## 6. Tests

1. `bindings()` for: a .NET-only project, a Rust-only project, a mixed .NET+Node
   project, a monorepo with two components selecting different SDK versions, and
   a project declaring nothing.
2. `verify()` per-component: each entry probed in its own cwd; one wrong
   component blocks and names it.
3. Identity: the same inputs produce the same digest across processes; a new
   candidate SHA does not need to equal the approved plan SHA. Evidence refers
   to the frozen approval plan, approved policy digest and exact candidate.
   Changed declarations, lockfiles and recipe content require review and cannot
   reuse old passing evidence.
4. Recipe selection: repository-declared runs, conventional does not without
   policy, no recipe reports unresolved.
5. Reported-version comparison: mismatch recorded, match silent, malformed
   receipt rejected as today.
6. The existing Herdr self-build path end-to-end, unchanged.
7. Both dashboards show the requirement, the bound executable and the plan
   digest for a task.

## 7. Non-goals and honest limits

- **This is not confinement.** Agents share the `herdr` Unix account, so an agent
  can still install a different SDK beside a managed one. These steps make the
  correct environment the path of least resistance and make divergence visible.
  Separation needs the identity or broker decision in
  `automatic-project-environments.md` §291–295.
- **Prose remains prose.** The instruction can be ignored; only the probe refuses.
  That is why the probe is the load-bearing part.
- **No new ecosystems here.** This slice changes the plumbing that carries
  requirements to the places that enforce them. Adapters remain WP2/WP4/WP5/WP7.

## 8. Open decisions

1. Whether `herdr agent` can receive environment variables (step 4's prerequisite).
2. Whether a conventional check recipe may ever become blocking automatically, or
   always needs an explicit organization policy selection.
3. Whether a reported-version mismatch should block delivery or only be recorded
   during the first migration, given agents currently self-install every tool
   outside the two adapter ecosystems.
