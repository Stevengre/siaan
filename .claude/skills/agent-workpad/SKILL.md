---
name: agent-workpad
description: >
  Defines the Agent Workpad convention — a persistent section embedded in the GitHub issue body
  that tracks plan, acceptance criteria, validation, notes, and confusions. Use this skill whenever
  creating a new issue that agents will work on, starting work on an issue (status:in-progress),
  or updating progress on an active issue. The workpad lives in the issue body below a `---`
  separator, never as a separate comment.
---

# Agent Workpad

The Agent Workpad is a **section in the issue body** (not a comment) that serves as the sole
source of truth for agent progress. Every issue an agent works on has this structure:

```
[Human-facing issue description]
  - Summary, approach, acceptance criteria, risks, etc.

---

## Agent Workpad
  - Plan, validation, notes, confusions
```

The `---` separator cleanly divides the human's intent from the agent's execution state. This
keeps everything in one place — no scattered comments, no separate tracking docs.

## Issue body structure

```markdown
## Summary
...

## Acceptance Criteria
- [ ] ...

## Risks
...

---

## Agent Workpad

`<hostname>:<workspace-path>@<short-sha>`

### Plan
- [ ] 1. First major task
  - [ ] 1.1 Subtask
  - [ ] 1.2 Subtask
- [ ] 2. Second major task

### Validation
- [ ] `make all` passes
- [ ] Manual verification of X

### Notes
- **YYYY-MM-DD HH:MM** — Started work, initial analysis shows...

### Confusions
- Unclear whether X should handle Y case — assuming Z for now
```

## How to update the workpad

Use `gh issue edit <number> --body "<full updated body>"` to update the issue body.
Read the current body first, modify only the workpad section below `---`, then write back
the full body.

## Workpad disciplines

These exist because agents that don't follow them produce workpads that are stale, misleading,
or useless to human reviewers.

1. **Update after every meaningful milestone.** Check off completed items, add notes with
   timestamps, revise the plan if scope changes.

2. **Never leave completed work unchecked.** The plan is an active execution checklist. When
   something is done, check it off immediately. Unchecked items signal "not started."

3. **Copy acceptance criteria from the issue.** If the issue body (above `---`) has acceptance
   criteria, copy them into the workpad's Validation section as checkboxes. These are
   non-negotiable gates.

4. **Edit in-place, don't append.** The workpad is not a log — it's a living document. Update
   sections directly. The Notes section is the exception: append timestamped entries there.

5. **Never touch content above `---`.** The human-facing description is the human's domain.
   The agent only modifies the workpad section below the separator.

## Rework protocol

When an issue moves from `status:review` back to `status:in-progress` (rework needed):

1. Reset the workpad: uncheck items that need rework, add a note explaining what changed
2. Close the existing PR if the reviewer requested it
3. Create a fresh branch from `origin/main` if needed
4. Continue updating the same workpad

## Completion bar

The workpad signals "ready for review" when ALL of these are true:

- [ ] Every Plan item is checked
- [ ] Every Validation item is checked and passing
- [ ] PR is created and linked to the issue
- [ ] CI checks are green
- [ ] All PR review comments are addressed

Only then should the agent transition the issue to `status:review`.
