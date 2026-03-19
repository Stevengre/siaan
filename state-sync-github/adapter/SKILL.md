---
name: state-sync-github-adapter
description: GitHub-backed state-sync adapter guidance. Use when changing GitHub issue sync, repository auth, pagination, or issue state transitions.
metadata:
  pattern: tool-wrapper
---

Load `lib/` for the GitHub state-sync adapter/client code.

Gotchas:
- Keep GitHub auth, pagination, and REST/GraphQL quirks in this folder.
- Convert GitHub issue payloads into the shared `SymphonyElixir.StateSync.Issue` shape before returning to the orchestrator.
- Merge automation helpers live in `../merge-automation/`, not in the shared interface.
