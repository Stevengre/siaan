---
name: gh-issue-config
description: Issue management reference — label taxonomy, status flow, human/agent boundaries, and closing criteria. Use as background context when working with issues, or when you need to understand the project's issue workflow conventions.
---

# Issue Management Configuration

This document defines the issue management conventions for this repository. All issue-related skills (triage, execution, review-gate) operate within this framework.

## Label Taxonomy

Every open issue requires **at minimum**: one `type:*`, one `status:*`, one `priority:*`, and usually one `area:*`.

### Type (exactly one)
| Label | Meaning |
|---|---|
| `type:epic` | Larger goal, usually contains sub-issues |
| `type:feature` | New capability or enhancement |
| `type:task` | Well-scoped, directly executable work |
| `type:bug` | Unexpected behavior or regression |
| `type:research` | Investigation to reduce uncertainty or make a decision |

### Status (exactly one for open issues)
| Label | Meaning |
|---|---|
| `status:triage` | New, not yet organized |
| `status:ready` | Clear and approved by human |
| `status:in-progress` | Actively being worked on |
| `status:blocked` | Waiting on explicit precondition |
| `status:review` | Implementation done, awaiting human review |
| `status:icebox` | Valuable but not being pursued now |

### Priority (exactly one)
| Label | Meaning |
|---|---|
| `priority:p0` | Critical path / most important now |
| `priority:p1` | Important but not most urgent |
| `priority:p2` | Valuable but can wait |

### Kind (optional, at most one)
`kind:refactor`, `kind:perf`, `kind:test`, `kind:docs`

### Area (usually one, max two)
`area:*` labels are repo-specific. Use when it improves filterability.

---

## Status Flow

Default path:
```
triage → ready → in-progress → review → close
```

Allowed transitions:
- `ready → blocked`, `in-progress → blocked`
- `review → in-progress` (rework needed)
- `triage → icebox`, `ready → icebox`
- `blocked → ready`, `icebox → ready`

### Transition Rules

| Transition | Requirements |
|---|---|
| `triage → ready` | Labels complete, scope clear, human reviewed and switched |
| `ready → in-progress` | Agent has started actual implementation/investigation |
| `→ blocked` | Only for explicit preconditions, not "hard" or "low priority" |
| `in-progress → review` | Main work done, primarily awaiting human review; human judges and switches |
| `review → in-progress` | Review found substantive rework needed |
| `blocked/icebox → ready` | Blocker resolved or re-prioritized; human confirms |

---

## Human / Agent Boundaries

### Agent CAN:
- Organize issue descriptions and context
- Propose labels, dependencies, risks
- Draft acceptance criteria
- Implement, test, document during `in-progress`
- Iterate based on human feedback in issue/PR comments
- Summarize and check during `review`

### Agent CANNOT:
- Set status to `ready` (human only)
- Close issues (human only)
- Switch `triage → ready` (human review + manual switch)
- Switch `review → close` (human review + manual close)
- Override human labels or decisions

**Principle: Agent advances work and proposes; only humans decide.**

### `in-progress` means:
Agent is actively working. Human guides via issue/PR comments. On conflict, human's latest explicit instruction wins.

---

## Closing Criteria (by type)

| Type | Closes when |
|---|---|
| `type:task` | Done condition or delivery target met |
| `type:bug` | Fixed and verified; or explicitly won't-fix / can't-reproduce |
| `type:feature` | Acceptance criteria met; or decided not to pursue |
| `type:research` | Clear conclusion, recommendation, or action plan produced |
| `type:epic` | Exit criteria met; remaining sub-items have clear disposition |

---

## PR Linking

PRs should reference issues: `closes #N`, `fixes #N`, or `refs #N`.

## Minimum Labeling Checklist

An issue missing any of these is considered un-triaged:
- [ ] One `type:*`
- [ ] One `status:*`
- [ ] One `priority:*`
- [ ] Usually one `area:*`
