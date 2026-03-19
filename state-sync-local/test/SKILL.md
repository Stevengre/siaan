---
name: state-sync-local-test
description: Run local implementation checks through the shared state-sync round-trip contract plus local filesystem assertions.
metadata:
  pattern: pipeline
---

Use the shared round-trip helpers from `../../state-sync/test/lib` and add local-only assertions for:
- file moves between workflow states,
- sidecar/workpad preservation,
- project config parsing and filter enforcement.
