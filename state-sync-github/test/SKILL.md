---
name: state-sync-github-test
description: Run GitHub implementation checks through the shared state-sync round-trip contract plus GitHub-specific assertions.
metadata:
  pattern: pipeline
---

Use the shared round-trip helpers from `../../state-sync/test/lib` and add GitHub-only assertions for:
- issue payload normalization,
- auth/config handling,
- merge automation readiness and PR feedback behavior.
