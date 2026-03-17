---
name: issue-config
description: Local markdown-driven issue management configuration — defines directory structure, frontmatter schema, status transitions, and human/agent boundaries for the local issue pipeline. Use as background context whenever working with local issues, creating/moving issue files, reading issue frontmatter, or when you need to understand the project's issue workflow conventions. Also use when the user mentions issue status, issue directories, workpads, or description formats.
---

# Local Issue Management Configuration

This document defines the local, markdown-driven issue management conventions. All issue-related agents (triage, in-progress, reflect, review, consistency) operate within this framework.

The core principle: **issues are local markdown files, status lives in both the directory path and the frontmatter, transitions are file moves + frontmatter updates.** No agent needs access to GitHub or any remote tracker — they only read and write local files. The directory is the source of truth for status; the frontmatter `status` field keeps each file self-describing.

## Directory Structure

Issues live at `~/.config/skills/issue-config/` organized by status:

```
~/.config/skills/issue-config/
├── config.toml                        # Storage and sync settings
├── triage/
│   └── <slug>.md                      # Single-file issue (new, unreviewed)
├── ready/
│   └── <slug>.md                      # Approved, waiting for execution
├── in-progress/
│   └── <slug>/                        # Multi-file directory during execution
│       ├── issue.md                   # Issue definition (frontmatter + body)
│       ├── workpad.md                 # Agent work log
│       └── description-<format>.md    # Generated descriptions (per frontmatter config)
├── review/
│   └── <slug>/                        # Same as in-progress, plus review artifacts
│       ├── issue.md
│       ├── workpad.md
│       ├── description-<format>.md
│       ├── consistency.json           # Cross-artifact alignment score
│       └── review.md                  # Review results
└── done/
    └── <slug>/                        # Archived (full artifact set)
```

### Single-file vs multi-file

- **triage/** and **ready/**: single `.md` file with frontmatter + body. The filename is the slug.
- **in-progress/**, **review/**, **done/**: directory named by slug, containing `issue.md` (the original issue content, moved from the single file) plus artifacts produced by each pipeline stage.

When an issue moves from `ready/` to `in-progress/`:
1. Create `in-progress/<slug>/`
2. Move `ready/<slug>.md` → `in-progress/<slug>/issue.md`
3. Create empty `in-progress/<slug>/workpad.md`

## Issue Frontmatter Schema

Every issue file uses YAML frontmatter for metadata. The body below the frontmatter is free-form markdown.

### Required fields

```yaml
---
project: siaan                          # Project identifier
title: Concise, action-oriented title   # Issue title
status: triage                          # Must match directory: triage | ready | in-progress | review | done
type: feature                           # Exactly one: epic | feature | task | bug | research
priority: p1                            # Exactly one: p0 | p1 | p2
area:                                   # Usually one, max two
  - orchestrator
  - agent-runner
---
```

### Optional fields

```yaml
---
kind: refactor                          # At most one: refactor | perf | test | docs
descriptions:                           # Description formats to generate (reflect agent uses this)
  - reviewer                            # Concise, focused on what changed and why
  - changelog                           # User-facing, focused on impact
  - technical                           # Deep dive into implementation details
skills:                                 # Skills needed for execution (installed on dispatch)
  - some-skill-name
blocked_by:                             # Slugs of blocking issues
  - other-issue-slug
agents:                                 # Resume commands using session names (not UUIDs)
  triage: "claude -r pipeline-triage"   # Named via /rename, TUI handles cd
  in-progress: "claude -r pipeline-impl"
sub_issues:                             # Required for epics — list of sub-issue slugs
  - sub-issue-one
  - sub-issue-two
---
```

### Type definitions

| Type | Meaning |
|---|---|
| `epic` | Larger goal, usually has sub-issues |
| `feature` | New capability or enhancement |
| `task` | Well-scoped, directly executable work |
| `bug` | Unexpected behavior or regression |
| `research` | Investigation to reduce uncertainty or make a decision |

### Priority definitions

| Priority | Meaning |
|---|---|
| `p0` | Critical path / most important now |
| `p1` | Important but not most urgent |
| `p2` | Valuable but can wait |

### Area labels

`area` values are project-specific. Use when it improves filterability. Common areas for siaan: `orchestrator`, `agent-runner`, `tracker`, `config`.

## Status Flow

Status is determined by which directory the issue lives in. Moving a file between directories is a status transition.

### Default path

```
triage/ → ready/ → in-progress/ → review/ → done/
```

### Epic readiness gate

An epic cannot move to `ready/` until its `sub_issues` field lists at least one sub-issue slug, and each listed sub-issue exists as a file in `triage/` or later. This ensures the decomposition is done before execution begins. Sub-issues can start as rough drafts and be refined iteratively — the gate only checks that they exist, not that they're perfect.

### Agents field

The `agents` frontmatter stores resume commands so the user (or TUI) can pick up a session where it left off.

**When to write:** Each agent writes its `agents.<stage>` entry **immediately after its first save** to the issue file — not at finalize, not later, right after the first write. Without this, the TUI shows "no session" and the user cannot resume.

**How:**
1. Agent runs `/rename <slug>-<stage>` (e.g., `/rename pipeline-triage`)
2. Agent writes `agents.<stage>: "claude -r <slug>-<stage>"` to frontmatter

The TUI reads the `project` field, looks up the project directory from `config.toml`, cds there, and execs the command.

```toml
# ~/.config/skills/issue-config/config.toml
[projects.siaan]
dir = "/Users/steven/Desktop/projs/siaan"
runtime = "local"
```

`runtime = "local"` means execution happens from the configured project directory on the
local machine. It does not dispatch the execution-stage skill to remote worker hosts.

### Allowed transitions

| From | To | Trigger |
|---|---|---|
| `triage/` | `ready/` | Human reviews and approves (epic: sub_issues must be populated) |
| `triage/` | `done/` | Won't do (human decision) |
| `ready/` | `in-progress/` | Agent begins execution |
| `ready/` | `triage/` | Needs rework before execution |
| `in-progress/` | `review/` | Agent completes main work |
| `in-progress/` | `ready/` | Blocked, return to queue |
| `review/` | `in-progress/` | Review found rework needed |
| `review/` | `done/` | Human approves and closes |

### Transition mechanics

Moving an issue = moving its file or directory **+ updating the `status` field in frontmatter**. Both must happen together — if they disagree, the directory is authoritative.

```bash
# triage → ready (human approves)
# 1. Update frontmatter: status: triage → status: ready
# 2. Move file
mv ~/.config/skills/issue-config/triage/my-issue.md \
   ~/.config/skills/issue-config/ready/my-issue.md

# ready → in-progress (agent starts, expand to directory)
# 1. Update frontmatter: status: ready → status: in-progress
# 2. Create directory and move
mkdir ~/.config/skills/issue-config/in-progress/my-issue/
mv ~/.config/skills/issue-config/ready/my-issue.md \
   ~/.config/skills/issue-config/in-progress/my-issue/issue.md

# in-progress → review (agent done, move whole directory)
# 1. Update frontmatter in issue.md: status: in-progress → status: review
# 2. Move directory
mv ~/.config/skills/issue-config/in-progress/my-issue/ \
   ~/.config/skills/issue-config/review/my-issue/
```

## Human / Agent Boundaries

### Agent CAN

- Create issue files in `triage/`
- Update issue content and frontmatter during their stage
- Create and write artifacts (workpad.md, description-*.md, consistency.json, review.md)
- Move issues forward in the pipeline (e.g., `in-progress/` → `review/`)
- Propose labels, dependencies, risks in frontmatter

### Agent CANNOT

- Move issues to `ready/` (human review + manual move)
- Move issues to `done/` (human review + manual move)
- Override human decisions or frontmatter set by humans
- Access remote systems (GitHub, Linear) — all operations are local

**Principle: agents advance work and propose; only humans decide readiness and completion.**

## Closing Criteria (by type)

| Type | Closes when |
|---|---|
| `task` | Done condition or delivery target met |
| `bug` | Fixed and verified; or explicitly won't-fix / can't-reproduce |
| `feature` | Acceptance criteria met; or decided not to pursue |
| `research` | Clear conclusion, recommendation, or action plan produced |
| `epic` | Exit criteria met; remaining sub-items have clear disposition |

## Pipeline Stages and Their Artifacts

Each stage of the pipeline produces specific artifacts:

| Stage | Agent | Reads | Writes |
|---|---|---|---|
| Triage | issue-triage | user input | `<slug>.md` in `triage/` |
| Execution | in-progress | `issue.md` + codebase | `workpad.md` + code changes |
| Reflect | reflect | `issue.md`, `workpad.md`, code diff | `description-<format>.md` (per frontmatter `descriptions` field) |
| Consistency | consistency | all artifacts + code | `consistency.json` |
| Review | review | all artifacts + `consistency.json` | `review.md` |

## Storage Configuration

The `config.toml` at the root of the issues directory controls storage behavior:

```toml
[storage]
# Where issues live (default: ~/.config/skills/issue-config/)
path = "~/.config/skills/issue-config/"

# Optional: sync with a git repository
[storage.sync]
enabled = false
# remote = "git@github.com:user/private-issues.git"
# auto_pull = true    # Pull on read
# auto_push = false   # Push on write (manual by default)
```

When sync is enabled, the issues directory is a git repo. `auto_pull` fetches latest before reading; `auto_push` commits and pushes after writes. Both default to manual operation.

## PR Linking and Branch Strategy

PRs should reference issues: `closes #N`, `fixes #N`, or `refs #N`.

When an issue has `blocked_by` relationships, the branch and PR must follow the dependency chain:

1. Check if the blocking issue has an open PR.
2. If yes, use that PR's branch as the base for the new branch (`--base <blocker-pr-branch>`).
3. If the blocker has no PR yet, fall back to `main` and note the dependency.

This mirrors the issue dependency graph in the git branch structure — dependent work stacks on top of prerequisite changes, reviewers see only incremental diffs, and when the blocker PR merges the dependent PR's base updates automatically.

## Minimum Metadata Checklist

An issue missing any of these is considered un-triaged:
- [ ] `title` set
- [ ] One `type` value
- [ ] One `priority` value
- [ ] At least one `area` (for non-trivial issues)
- [ ] `descriptions` field set (so reflect agent knows what to generate)
- [ ] `agents.triage` set (so the user can resume the triage session)

Additional for epics (required before `ready/`):
- [ ] `sub_issues` lists at least one sub-issue slug
- [ ] Each listed sub-issue exists as a file in `triage/` or later
