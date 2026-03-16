---
name: pr-description
description: >
  Draft a reviewer-focused PR description using Change Proof as the approval
  surface and Architecture Trace as the appendix. Use when creating or updating
  a PR body from issue context + diff.
---

# PR Description

Use this skill when a PR body needs to be authored or refreshed.

## Goal

Produce a PR description that lets a reviewer answer all 6 verification
questions from the issue:

1. What behavior changed?
2. What must still hold?
3. Where is this most likely to regress?
4. What evidence covers those risks?
5. What stayed outside the blast radius?
6. How would we detect and roll back a production failure?

## Inputs

- The issue/specification that the PR closes
- The current diff against the base branch
- Validation evidence already gathered in-session
- The final PR title / scope on the branch

## Workflow

1. Read the issue/spec and identify the core claim of the change.
2. Inspect the diff and group files into independent change groups.
   - If the PR has multiple unrelated changes, each group gets its own full
     Change Proof block.
3. For each change group, draft the top-level sections in this order:
   - `### Behavior Delta`
   - `### Invariants / Non-goals`
   - `### Validation`
   - `### Risk / Blast Radius / Rollback`
   - `### Review Focus`
4. Keep Change Proof falsifiable.
   - Prefer before/after behavior, invariants, commands, traces, and concrete
     outputs.
   - Do not treat navigation links as evidence.
5. Add the appendix exactly once:
   - Wrap it in `<details>` with summary `Architecture Trace`
   - Include all 5 sections:
     - `### Context (C4-L1)`
     - `### Container (C4-L2)`
     - `### Component (C4-L3)`
     - `### Code Trace (C4-L4)`
     - `### Decision Record`
   - If a C4 level is not relevant, keep the heading and explain why it is
     excluded instead of deleting it.
6. Choose diagrams by PR type:
   - Behavior change: mermaid sequence or state transition
   - Cross-service/module: mermaid component plus sequence
   - Pure refactor: before/after component diagram
   - Data model change: ER or schema before/after
   - Config/infra: deployment diagram
7. Decision Record rules:
   - Include alternatives considered and trade-offs
   - If there is no design decision, write exactly:
     `No design decision introduced in this PR.`
8. Validate the final body against `.github/PULL_REQUEST_TEMPLATE.md`:

```bash
tmp_pr_body=$(mktemp)
# write the draft body to "$tmp_pr_body"
(cd elixir && mix pr_body.check --file "$tmp_pr_body")
rm -f "$tmp_pr_body"
```

## Authoring Rules

- Use concrete statements, not generic prose.
- State unchanged behavior explicitly.
- Include rollback and detection even for small changes.
- For pure refactors, set the behavior delta to no user-visible change and let
  invariants/validation carry the approval argument.
- Refresh the full PR body whenever scope changes; do not append stale notes to
  an outdated draft.
