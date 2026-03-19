# Workflow Engine Interpreter

Use this folder when you need to execute a Mermaid-defined state machine.

## Semantics

- Load Mermaid text through the parser to obtain a machine definition.
- Enter the machine at its declared initial state.
- Run any activities attached to the entered state.
- Evaluate outgoing transitions in file order.
- A transition is eligible when its condition passes, or when it has no condition.
- When a transition fires:
  - run its actions in order,
  - move into the target state,
  - run the new state's activities.
- Reaching `[*]` ends the machine.

## Runtime Contract

- Conditions are opaque identifiers resolved by the caller.
- Activities are opaque identifiers resolved by the caller.
- Actions are opaque identifiers resolved by the caller.
- The interpreter itself must not know anything about GitHub issues, PRs, or tracker APIs.
