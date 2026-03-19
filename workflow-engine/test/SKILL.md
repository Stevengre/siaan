---
name: workflow-engine-test
description: >
  Test guide for validating workflow-engine parser, interpreter, validator,
  and example workflows. Use when proving workflow-engine behavior.
---

# Workflow Engine Test Guide

Use this folder for focused proof that the parser, interpreter, validator, and example workflows behave as expected.

## Minimum Proof

- Parse a Mermaid workflow with state notes and transition annotations.
- Execute a workflow path where one transition condition fails and the next passes.
- Detect unreachable states, deadlocks, and missing conditions.
- Parse and validate the current GitHub issue workflow example.
