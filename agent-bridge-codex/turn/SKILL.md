---
name: agent-bridge-codex-turn
description: >
  Codex bridge turn execution wrapper covering turn startup, streamed message
  handling, completion waiting, timeout behavior, and failure propagation.
---

# Codex Turn Bridge

Owns turn execution for the Codex bridge.

- Start turns on an existing thread.
- Stream turn messages until completion, timeout, or failure.
- Emit bridge message events for orchestrator consumers.
