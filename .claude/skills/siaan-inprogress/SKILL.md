---
name: siaan-inprogress
description: Execution-stage local issue skill for the local-first orchestrator. Reads `issue.md`, updates `workpad.md`, performs implementation work in the project repo, and expresses transition intent by writing `status: review` in the workpad frontmatter.
---

# siaan-inprogress

## Purpose

This skill replaces the execution-stage behavior that previously lived inside `elixir/WORKFLOW.md`.
It is designed for local-file-driven issue execution.

## Inputs

The orchestrator renders and passes these values into the prompt template:

- `issue.identifier`
- `issue.title`
- `issue.state`
- `issue.issue_path`
- `issue.workpad_path`
- `issue.issue_dir`
- `issue.project_dir`
- `issue.base_branch`
- `issue.current_branch`

## Working directory

The orchestrator runs the agent from the configured project directory when the project
config sets `runtime = "local"`.

If that project directory is missing or unreadable, dispatch fails before the skill
starts.

`runtime = "local"` is local-machine-only. The orchestrator will not dispatch this
skill to remote worker hosts.

## File permissions

- Read-only: `issue.md`
- Read/write: `workpad.md`
- Read/write: project files under the configured project directory

The skill must not:

- modify `issue.md`
- move issue files or directories
- update remote tracker state directly

## Transition intent

When implementation and validation are complete, the skill expresses handoff intent by writing this frontmatter in `workpad.md`:

```yaml
---
status: review
---
```

The orchestrator remains the only component allowed to perform the actual state transition.

The workpad frontmatter must remain valid YAML frontmatter bounded by opening and closing `---` lines.

## Success and failure semantics

- Success: the agent finishes normally and leaves the workpad in the desired state for the orchestrator to evaluate.
- Failure: the agent exits non-zero or leaves an invalid/incomplete workpad; the orchestrator keeps the issue in its current state or routes it through the configured retry/blocking logic.
