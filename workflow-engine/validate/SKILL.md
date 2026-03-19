# Workflow Validator

Use this folder to review a Mermaid-defined workflow before execution.

## Required Checks

- Initial state exists.
- Every transition source and target resolves to a known state or `[*]`.
- Unreachable states are reported.
- Deadlock states are reported.
- Decision transitions without named conditions are reported.

## Output Expectations

- Return structured findings that a reviewer can act on.
- Keep engine findings generic; do not encode tracker-specific rules.
