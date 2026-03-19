---
name: state-sync-local-adapter
description: Local-file state-sync adapter guidance. Use when changing local issue layout, workflow transitions, or project config parsing.
metadata:
  pattern: tool-wrapper
---

Load `lib/` for the local state-sync adapter, workflow loader, and project config parser.

Gotchas:
- The local project config uses `[projects.<name>.state]` as the canonical implementation config section.
- Preserve frontmatter and sidecar files during state transitions.
- Keep workflow-specific transition logic local to this folder.
