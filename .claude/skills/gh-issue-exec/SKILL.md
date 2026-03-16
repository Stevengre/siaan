---
name: gh-issue-exec
description: >
  Executes an in-progress GitHub issue end-to-end: creates an isolated git worktree, reads the
  Agent Workpad from the issue body, follows the plan with TDD discipline, updates the workpad
  after each milestone, creates a PR linking the issue, and transitions status:in-progress →
  status:review when the completion bar is met. Use when the user points to an issue number and
  says to work on it, implement it, or execute it — and the issue is already in-progress.
---

# Issue Execution

Execute a `status:in-progress` issue in an isolated worktree, following its Agent Workpad,
and deliver a PR.

## Input

An issue number. The issue must:
- Have `status:in-progress` label
- Have an Agent Workpad section in the body (below `---` separator)

## Workflow

### 1. Create an isolated worktree

Work in a dedicated git worktree so the main working tree stays clean. Each issue gets its
own branch and worktree under `.worktrees/`:

```bash
BRANCH="issue-<number>-<short-description>"
WORKTREE=".worktrees/$BRANCH"
git worktree add "$WORKTREE" -b "$BRANCH"
cd "$WORKTREE"
```

All subsequent work happens inside this worktree. This isolation means multiple issues can
be worked on in parallel without interfering with each other or the main branch.

### 2. Read the issue

```bash
gh issue view <number> --json body,title,number,labels,assignees
```

Parse the body into two parts:
- **Above `---`**: human-facing description, acceptance criteria, risks
- **Below `---`**: Agent Workpad (plan, validation, notes, confusions)

### 3. Understand the work

Before touching code, read and internalize:
- The **Plan** checklist — this is the execution order
- The **Acceptance Criteria** (from above `---`) — these are the gates
- The **Validation** section — these must all pass before you're done
- The **Confusions** section — address or ask about these early

### 4. Execute the plan, step by step

For each plan item:

1. **If the step involves code, write the test first.** This is TDD — the test defines what
   "done" means for that step. Run it, confirm it fails, then implement.

2. **Do the work.** Write code, modify config, add files — whatever the step requires.

3. **Run tests.** The new test should pass. Existing tests should not break.

4. **Check off the plan item** and add a timestamped note.

5. **Update the workpad** in the issue body. Read the current body, modify only the workpad
   section below `---`, write back the full body:
   ```bash
   gh issue edit <number> --body "<full updated body>"
   ```

The workpad update cadence matters. Update after every meaningful milestone — a completed plan
item, a surprising finding, a deviation from the plan. Stale workpads are worse than no workpad
because they mislead reviewers.

### 5. Handle surprises

If something unexpected comes up during execution:

- **Scope change needed**: Add a note in Confusions, do NOT change the plan without flagging it.
  If the change is significant, stop and ask the human via an issue comment.

- **Blocker**: Add a note, comment on the issue explaining what's blocked and why. Do NOT
  change labels yourself — suggest `status:blocked` and let the human decide.

- **Test failure in existing code**: Investigate. Don't silently skip or disable tests.
  If it's a pre-existing issue unrelated to your work, note it in Confusions and move on.

### 6. Create the PR

When all plan items are checked and validation passes:

Use the `pr-description` skill to draft the PR body from the issue context,
diff, and validation evidence before creating or editing the PR.

```bash
git push -u origin HEAD
gh pr create --title "<concise title>" --body "$(cat <<'EOF'
<full body matching .github/PULL_REQUEST_TEMPLATE.md>
EOF
)"
```

Ensure the final body contains `closes #<number>` so the PR auto-links to the
issue.

### 7. Check the completion bar

Before transitioning to review, verify ALL of these:

- [ ] Every Plan item is checked
- [ ] Every Validation item is checked and passing
- [ ] PR is created and linked to the issue
- [ ] CI checks are green (check with `gh pr checks <pr-number>`)
- [ ] All PR review comments are addressed (if any early feedback came in)

If anything is missing, go back and finish it. Don't transition with incomplete work.

### 8. Transition to status:review

When the completion bar is fully met:

```bash
gh issue edit <number> --remove-label "status:in-progress" --add-label "status:review"
```

Update the workpad one final time with a completion note:
```
### Notes
- **YYYY-MM-DD HH:MM** — All plan items complete, validation passing, PR #<pr> created. Transitioning to status:review.
```

### 9. Clean up worktree (optional)

After the PR is merged, the worktree can be removed:
```bash
cd /path/to/main/repo
git worktree remove .worktrees/<branch>
```

Don't clean up before merge — the worktree may be needed for rework after review.

## Commit discipline

- Each plan step gets its own commit (or a small group of related commits)
- Commit messages reference the issue: `#<number>: <what changed>`
- Don't squash everything into one giant commit — reviewers need to follow the progression

## What NOT to do

- Don't work directly on main — always use the worktree
- Don't start if the issue is not `status:in-progress`
- Don't modify content above `---` in the issue body — that's the human's domain
- Don't close the issue — only humans close issues
- Don't skip tests to move faster — TDD is the contract
- Don't transition to `status:review` with unchecked items
- Don't create multiple PRs for one issue unless explicitly needed
