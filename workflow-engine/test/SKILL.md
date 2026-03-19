# Workflow Engine Test Guide

Use this folder for focused proof that the parser, interpreter, validator, and example workflows behave as expected.

## Minimum Proof

- Parse a Mermaid workflow with state notes and transition annotations.
- Execute a workflow path where one transition condition fails and the next passes.
- Detect unreachable states, deadlocks, and missing conditions.
- Parse and validate the current GitHub issue workflow example.
