---
name: state-sync-interface
description: Shared state-sync boundary, types, and implementation selection rules. Use when wiring orchestrator code to a state sync implementation or reviewing cross-implementation contracts.
metadata:
  pattern: tool-wrapper
---

Load `lib/` for the canonical state-sync behaviour and shared issue struct.

Gotchas:
- Keep implementation-neutral code here. GitHub- or local-specific API behavior does not belong in this folder.
- The runtime config contract is `[state]` with `type = "github" | "local"` for the active implementations in this repo.
- Cross-folder calls should go through the shared behaviour, not direct implementation coupling.
