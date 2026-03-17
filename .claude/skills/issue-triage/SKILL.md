---
name: issue-triage
description: >
  Turn rough ideas, problems, or thoughts into well-structured GitHub issues through interactive refinement.
  Use when the user invokes `/issue-triage` followed by their ideas, or when they say things like
  "I have an idea for...", "we should fix...", "let me describe a problem...", "help me write an issue for...",
  "turn this into an issue". Works in any language the user writes in.
---

# Issue Triage — Idea to Issue

Take a rough idea or problem description and refine it into a well-structured local issue through interactive discussion. The skill drafts aggressively, asks targeted questions, and iterates until the issue is ready. Output goes to `~/.config/skills/issue-config/triage/` following the `issue-config` skill conventions.

## Configuration

### Auto-detected (no user input needed)

- **Discussion language**: Match the language of the user's input. All drafts, questions, and discussion happen in that language.
- **Target repository**: Detect from the current working directory (`gh repo view --json nameWithOwner -q .nameWithOwner`).

### Manual config — `.config/skills/issue-triage.toml`

On first run, check if `.config/skills/issue-triage.toml` exists in the repo root. If it does, load it and confirm settings with the user. If it doesn't, ask the user about these settings, then save the file so future runs skip this step.

The config is organized by project. The project name is derived from the current directory name (e.g., working in `/Users/alice/projs/siaan` → project = `siaan`).

```toml
[global]
# Default settings applied to all projects unless overridden
issue_language = "en"           # Language for published issues: "en", "zh", "ja", "same" (= discussion language)
drafts_dir = ".config/skills/issue-triage/drafts"  # Local directory for drafts (relative to repo root)

[projects.siaan]
# Override settings for the "siaan" project
issue_language = "en"
drafts_dir = ".config/skills/issue-triage/drafts"
# repo = "owner/siaan"         # Optional: override auto-detected repo

[projects.another-project]
issue_language = "zh"
drafts_dir = "docs/issue-drafts"
```

Resolution order: `projects.<name>` → `global` → built-in defaults (`issue_language = "same"`, `drafts_dir = ".config/skills/issue-triage/drafts"`).

## Workflow

### 1. Bootstrap

- Load `issue-config` skill for frontmatter schema, status rules, and directory structure.
- Ensure `~/.config/skills/issue-config/triage/` exists.
- Load config from `~/.config/skills/issue-triage/config.toml` (or create it on first run).
- Ensure `~/.config/skills/issue-config/config.toml` has a project entry for the current repo with at least:
  ```toml
  [projects.<name>]
  dir = "/path/to/<name>"
  runtime = "local"
  ```

### 2. First Draft — Guess Boldly

Read the user's input and immediately produce a **complete first draft** of the issue. Don't wait for perfect information — make reasonable assumptions and mark them clearly. The goal is to give the user something concrete to react to, which is faster than answering abstract questions.

**Language rule:** The draft is always written in the **discussion language** (the language the user is using). Translation to `issue_language` happens later, only when moving to `ready/`. This keeps the triage phase natural — the user reads, edits, and discusses in their own language.

The draft file uses YAML frontmatter for metadata and markdown for the body:

```markdown
---
project: siaan
title: Concise, action-oriented title
status: triage
type: feature
priority: p1
area:
  - core
  - api
---

## Problem / Goal

...

## Proposed Approach

...

## Acceptance Criteria

- [ ] ...
- [ ] ...

## Assumptions

- [guess] ...
- [guess] ...
```

The frontmatter captures all label metadata. The body contains the issue content. During iteration, update both frontmatter and body in place as things get refined.

**Immediately after writing the first draft file, do these three things in order:**

1. **Save** the draft to `~/.config/skills/issue-config/triage/<slug>.md`
2. **Rename** the current session: run `/rename <slug>-triage`
3. **Write** the resume command into the draft frontmatter:
   ```yaml
   agents:
     triage: "claude -r <slug>-triage"
   ```

Steps 2 and 3 are mandatory — without them the user cannot resume this triage session from the TUI. Do not skip them, do not defer them to "finalize". They happen right after the first save.

If `issue_language` differs from the discussion language, also maintain a translated copy at `~/.config/skills/issue-config/triage/<slug>-<lang>.md` for discussion purposes. The slug-only file is always the issue-language version.

### 2b. Epic Decomposition

If the issue `type` is `epic`, immediately after the first draft, propose a breakdown into sub-issues. Generate draft sub-issue files — they don't need to be perfect, just concrete enough for the user to react to.

For each sub-issue:
1. Create a separate file at `~/.config/skills/issue-config/triage/<sub-slug>.md`
2. Include minimal frontmatter (title, type, priority, area) — guess boldly
3. Add the sub-issue slug to the epic's `sub_issues` frontmatter list

The decomposition is iterative:
- Present all sub-issues as a numbered list with one-line summaries
- Ask which ones to keep, merge, split, or remove
- Update the files in place as the user refines
- An epic cannot leave triage without at least one sub-issue defined (per `issue-config` rules)

It's fine to start with rough drafts and refine over multiple rounds. The goal is to make decomposition feel lightweight — the user should be able to say "split #3 into two" or "merge #1 and #2" and see immediate updates.

### 3. Targeted Questions

After presenting the draft, ask 3-5 focused questions to address the biggest unknowns. Prioritize questions that would change the shape of the issue (scope, approach, priority) over details that can be filled in later. Structure questions as multiple-choice or yes/no when possible to minimize user effort.

Examples of good questions:
- "I assumed this is a new feature, but could it also be a bug fix for existing behavior?"
- "Should this be scoped to just X, or also cover Y?"
- "Does this block or depend on any existing issue?"

### 4. Iterate

As the user answers questions or gives feedback:
- Update the draft file in-place (don't create new version files — edit the same `<project>-<slug>-<lang>.md`)
- Keep asking questions if new unknowns emerge, but reduce the number as convergence happens
- When the user seems satisfied or says something like "looks good" / "ok" / "可以了", move to finalization

### 5. Finalize (triage complete, not yet ready)

- Present the final version for confirmation
- Ensure `agents.triage` is set in frontmatter
- For epics: verify `sub_issues` is populated and all listed sub-issue files exist in `triage/`
- Report what was created: file path, sub-issues (if epic), resume command

The issue stays in `triage/` in the **discussion language**. Triage is done — but the issue is not ready yet. A human reviews and decides when to move it to `ready/`.

### 6. Move to ready (human-triggered, translation happens here)

When a human decides the issue is ready:

1. If `issue_language` differs from the discussion language, **translate** the issue body to `issue_language` while preserving technical terms and frontmatter
2. Update `status: ready` in frontmatter
3. Move the file to `~/.config/skills/issue-config/ready/<slug>.md`

Translation only happens at this step — never during triage. This ensures the user always works with the issue in their own language during discussion.

## Principles

- **Draft first, ask second**: A concrete draft is worth ten abstract questions. Let the user react to something tangible.
- **Respect the user's language**: The entire triage phase uses the discussion language. Translation to `issue_language` only happens when moving to `ready/` — never before.
- **Don't over-polish**: The goal is a clear, actionable issue — not a literary masterpiece. Stop when it's good enough.
- **Edit in place**: Don't create version history of drafts. One file per language, updated in place as the issue evolves.

## Do Not

- Do not create a GitHub issue without explicit user approval.
- Do not silently change the user's intent or scope.
- Do not ask more than 5 questions at once — keep it focused.
