# Task review and GitHub publishing

A validated candidate has passed its configured checks. Group discussion
finalization means the discussion output is ready, not that the candidate was
approved. Read the findings before completing the task. A follow-up may fix an
unmet acceptance criterion or propose an independent improvement; creating a
draft does not record which of those applies.

The task page shows the latest group review and its findings. New reviews record
the candidate SHA. An older candidate, or a legacy review without a recorded
candidate, needs comparison against the latest changes. Independent acceptance
review results remain visible separately. The full discussion and its proposal
actions are under Activity & agents.

## Configure GitHub

As a dashboard administrator, open Tasks → GitHub publishing, or choose
Set up GitHub publishing on a task. Supply:

- A fine-grained personal access token belonging to an account with push access
  to the selected repositories. Select the repository owner as resource owner,
  choose the repositories, set an expiry, and obtain organization approval if
  the organization requires it.
- Repository permissions: Contents write, Pull requests write, Checks read and
  Commit statuses read. Publishing workflow changes may also require Workflows
  write. Keep branch protection enabled.
- An allowlist of 1–20 repositories, one `owner/repository` per line. For this
  repository that is `Ultarius/herdr_proxmox`. The task's GitHub origin must match
  an allowlisted repository.

Validate and save checks the GitHub account and push access for every repository.
It does not exercise every later operation or guarantee all token permissions.
The gateway needs working Internet routing and DNS. Publishing uploads the exact
reviewed commit; it does not merge or deploy it. Pull request creation and
subsequent GitHub review are separate actions in the task workflow.

After publication, open Changes → Open draft PR. The dashboard fetches a fresh
preview, shows the repository, source branch, base branch and exact candidate
SHA, and lets you edit the public title and Markdown description. Cancel sends
no PR request. Create draft PR submits the edited text with explicit approval
for that SHA; a changed candidate requires a new preview. New PR creation
without this approval is rejected by the gateway, including requests from an
older dashboard version. Existing PR reconciliation remains available.

The suggested body includes task context, current-candidate validation and
check results, acceptance-review state, discussion references, follow-up task
IDs, and a section to fill in risks and limitations. Worker-reported checks are
labeled separately from durable verification. The finalized discussion excerpt
is offered as a separate opt-in and is left out of the default body, because it
publishes the group's deliberation verbatim. Review and complete these sections
before submission; the generator does not infer acceptance or approval from
successful tests.

Approving the text records its SHA-256 and the exact candidate, not the text
itself. The description already exists on GitHub, and the task record is served
in full by the task list, so storing it there would add up to 30 KB per task for
no reader.

Publication and PR creation remain separate. A PR permission failure retains
the published branch and reports that fact. Retrying reconciles any existing
PR rather than pushing again or updating its title/body silently. Both account
repository access and token permissions limit authority; setup's read-only
account-access check cannot guarantee token write permission. Fine-grained
tokens need Contents write, plus Workflows write when workflows change;
classic tokens use the corresponding repo and workflow scopes.

Tokens are stored server-side with restrictive file permissions and omitted from
snapshots. Gateway and agents currently share a Linux user, so this is not
credential isolation from same-user agents. The setup dialog explains this.

GitHub reference:
https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

## Agent ownership and follow-ups

Task completion and execution completion are separate. A follow-up draft does
not reserve its assigned agent. A finished implementation may hand its agent
to the next queued task while the original remains Review ready.

The scheduler verifies the previous execution's receipt against the exact
candidate, a clean assigned checkout without an unfinished Git operation,
the live session identity and settled state, and absence of discussion
reservations. It archives the context and closes the verified session before
starting the next task. Failed checks retain ownership and require inspection.

A group proposal alone cannot replace these checks. It can discuss work that
is still running, recommend optional improvements, or refer to an earlier
candidate. Likewise, an idle pane by itself is not proof of completed work.
