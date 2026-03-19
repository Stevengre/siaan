---
name: state-sync-design
description: Design a new state-sync implementation by interviewing for runtime, API, and validation requirements before writing code.
metadata:
  pattern: inversion
---

Ask one question at a time before proposing an implementation:
1. What source of truth owns issue state and comments?
2. What read/write operations must the implementation support?
3. What auth, rate-limit, or filesystem constraints apply?
4. What round-trip validation proves the implementation preserves orchestrator behavior?

Only after those answers are clear:
- Define the shared behaviour coverage against `state-sync/interface/lib`.
- Define implementation-only gotchas.
- Define the test plan that plugs into `state-sync/test/lib`.
