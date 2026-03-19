# Workflow Engine

This folder hosts a self-contained state machine engine whose configuration language is Mermaid `stateDiagram`.

## Research Findings

1. Mermaid `stateDiagram` covers the core graph structure cleanly: states, aliases, start/end nodes, and ordered transitions.
2. Mermaid alone does not encode executable metadata such as conditions or state-entry skills, so this engine adds small text conventions:
   - State metadata lives in Mermaid `note ... of <state>` blocks.
   - Transition metadata lives in bracket annotations inside the transition label, for example `[condition: checks_pass] [action: prepare_handoff]`.
3. The current GitHub issue lifecycle is expressible with this model without hard-coding GitHub into the engine. The example workflow lives in [`workflow-engine/examples/github_issue_workflow.mmd`](./examples/github_issue_workflow.mmd).

## Extension Conventions

- State activities:
  - Add one or more `activity: <ref>` lines inside a note block attached to the state.
- Optional state metadata:
  - Add `terminal: true` or any other `key: value` pair inside the note block.
- Transition conditions/actions:
  - Use a Mermaid label with optional bracket annotations, for example:
    - `dispatch [condition: issue_is_ready] [action: mark_started]`

## Layout

- `mermaid-parser/`: Mermaid text -> internal machine representation
- `interpreter/`: transition selection and activity/action execution semantics
- `validate/`: graph analysis for deadlocks, unreachable states, and missing conditions
- `design/`: guidance for authoring new workflows
- `test/`: shared examples used by automated proof
