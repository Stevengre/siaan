---
name: agent-bridge-codex-test
description: >
  Codex-specific bridge test support and validation guidance for extracted
  session, turn, approval, and compatibility behavior.
---

# Codex Bridge Tests

Holds Codex-specific bridge contract helpers and fixtures.

- Reuse the generic `agent-bridge/test` contract macros against the Codex bridge.
- Keep fake Codex binary setup isolated from orchestrator tests when adding coverage.
