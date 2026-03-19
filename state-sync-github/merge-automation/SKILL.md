---
name: state-sync-github-merge-automation
description: GitHub PR feedback, approval, and auto-merge guidance. Use when checking merge readiness or answering PR blocker comments.
metadata:
  pattern: tool-wrapper
---

Load `lib/` for the GitHub-only merge automation helpers.

Gotchas:
- These helpers are intentionally outside the shared state-sync boundary.
- Unsupported implementations should return safe fallbacks instead of leaking GitHub assumptions.
- Keep user-facing PR automation checks prefixed around actionable feedback, approvals, CI, and mergeability.
