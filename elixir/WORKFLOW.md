---
tracker:
  kind: github
  repo_owner: "Stevengre"
  repo_name: "siaan"
  active_states:
    - status:ready
    - status:in-progress
  watch_states:
    - status:review
  terminal_states:
    - closed
polling:
  interval_ms: 30000
workspace:
  root: ~/code/workspaces/siaan
hooks:
  after_create: |
    git clone --depth 1 https://github.com/Stevengre/siaan .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 5
  max_turns: 7
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=medium --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  read_timeout_ms: 30000
  stall_timeout_ms: 900000
allowlist:
  - Stevengre
  - siaan-bot
  - chatgpt-codex-connector[bot]
---

You are working on a GitHub issue `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: GitHub MCP or `github_graphql` tool is available

The agent should be able to talk to GitHub, either via a configured GitHub MCP server or injected `github_graphql` tool. If none are present, stop and ask the user to configure GitHub.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent GitHub issue comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate GitHub issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be labeled
  `status:triage`, link the current issue as `related`, and use a blocker
  reference when the follow-up depends on the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `github`: interact with GitHub.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.

## Status map

- `status:triage` -> out of scope for this workflow; do not modify.
- `status:ready` -> queued; immediately transition to `status:in-progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `status:review`).
- `status:in-progress` -> implementation actively underway.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `status:triage` -> do not modify issue content/state; stop and wait for human to move it to `status:ready`.
   - `status:ready` -> immediately move to `status:in-progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `status:in-progress` -> continue execution flow from current scratchpad comment.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `status:ready` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "status:in-progress")`
   - find/create `## Agent Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (`status:ready` or `status:in-progress`)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Agent Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `status:ready`, do not delay on additional status transitions: the issue should already be `status:in-progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
6.  Run a principal-style self-review of the plan and refine it in the comment.
7.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
8.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
9.  Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `status:review`:

**All PR comments and replies posted by the agent must be prefixed with `[siaan]`.**

1. Identify the PR number from issue links/attachments.
2. If `@codex` review has not yet been requested on the current PR revision, post this exact PR comment:
   - `@codex please review the changes in this PR against the base branch \`{base_branch}\` and the original specification in {issue_url}.`
   - Replace `{base_branch}` with the actual PR base branch name.
   - Replace `{issue_url}` with the full issue URL.
3. Gather **ONLY** feedback from `{{ allowlist }}` across all channels:
   - Top-level PR comments (`gh pr view <pr> --json comments --jq '.comments[] | select(.author.login as $login | "{{ allowlist }}" | split(", ") | index($login))'`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments --jq '.[] | select(.user.login as $login | "{{ allowlist }}" | split(", ") | index($login))'`).
   - Review summaries/states (`gh pr view <pr> --json reviews --jq '.reviews[] | select(.author.login as $login | "{{ allowlist }}" | split(", ") | index($login))'`).
4. For any non-actionable comment from `{{ allowlist }}`, reply briefly with the disposition; if it is thread-based, resolve it when appropriate.
5. Treat every actionable comment from `{{ allowlist }}` as blocking until one of these is true:
   - code/test/docs updated to address it, with a reply that includes the commit SHA and a brief fix summary, and resolve the thread when that feedback is thread-based, or
   - explicit, justified pushback reply is posted on that feedback item.
6. Amend the existing workpad plan/checklist in place to include each feedback item and its resolution status.
7. Re-run validation after feedback-driven changes and push updates.
8. Repeat this sweep until there are no outstanding actionable comments from `{{ allowlist }}`.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `status:review` for GitHub access/auth until all fallback strategies have been attempted and documented in the workpad.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `status:review` with a short blocker brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (`status:ready` -> `status:in-progress` -> `status:review`)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `status:ready`, move it to `status:in-progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `status:ready` with an attached PR, address existing actionable PR feedback from `{{ allowlist }}` before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Create or update a PR whose body includes `closes #<issue-number>` to auto-link it to the issue.
    - If PR creation is unavailable, record the PR URL in the workpad comment as a fallback.
    - Ensure the GitHub PR has label `siaan` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Handoff to review:
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
    - Request `@codex` review exactly once by posting this PR comment:
      `@codex please review the changes in this PR against the base branch \`{base_branch}\` and the original specification in {issue_url}.`
    - Move issue to `status:review` immediately after requesting review. Do not wait for the review result.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `status:review` with the blocker brief and explicit unblock actions.
13. For `status:ready` tickets that already had a PR attached at kickoff:
    - Ensure all existing actionable PR feedback from `{{ allowlist }}`, including inline review comments, was reviewed and resolved.
    - Ensure branch was pushed with any required updates.
    - Then move to `status:review`.

## Step 3: Fix blockers (`status:in-progress` with existing PR)

When dispatched for an issue that already has a PR and workpad (e.g., after orchestrator transitions from `status:review` due to merge blockers):

1. Keep the existing PR, branch, and workpad — do not start over.
2. Identify what is blocking the merge. Common blockers:
   - **CI failures** -> fix the issue, commit, push.
   - **Merge conflicts** -> use the `pull` skill to merge `origin/main`, resolve conflicts, push.
   - **Unanswered PR comments** -> reply to each with a `[siaan]`-prefixed response, resolve conversations.
   - **Actionable review feedback** -> address feedback, commit, push.
3. After all blockers are resolved, follow the handoff flow (Step 2.11) to move back to `status:review`.
4. Do **not** merge the PR directly — the orchestrator handles merging when all conditions are met.

## Completion bar before `status:review`

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- `@codex` review has been requested on the current PR revision.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`siaan` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `status:triage`, do not modify it; wait for human to move to `status:ready`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Agent Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate `status:triage` issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `status:review` unless the `Completion bar before status:review` is satisfied.
- If the issue is in any state other than `status:ready` or `status:in-progress`, do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Agent Workpad

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
