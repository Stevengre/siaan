---
name: state-sync-test
description: Validate a state-sync implementation against the shared round-trip contract. Use when adding or modifying a GitHub or local state-sync implementation.
metadata:
  pattern: pipeline
---

Run this validation pipeline in order:
1. Load the generic round-trip helpers from `lib/`.
2. Exercise candidate fetch, state transition, and state refresh for the implementation under test.
3. Confirm the resulting issue payload still matches the shared state-sync issue contract.
4. Fail if implementation-specific behavior leaks into the shared interface surface.
