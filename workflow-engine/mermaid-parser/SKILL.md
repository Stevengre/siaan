# Mermaid State Diagram Parser

Use this folder to convert Mermaid `stateDiagram` text into the workflow engine's internal representation.

## Supported Syntax

- `stateDiagram` and `stateDiagram-v2`
- `state "Label" as id`
- `state id`
- `[*] --> state_id`
- `source --> target`
- `source --> target: event [condition: cond_name] [action: action_name]`
- `note right of state_id ... end note`

## Engine Extensions

- `activity: <ref>` lines inside a state note bind state-entry activities.
- Any other `key: value` line inside a note is stored as metadata.
- Transition annotations use bracket syntax and stay opaque to the parser.
