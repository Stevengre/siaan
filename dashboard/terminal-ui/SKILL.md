---
name: dashboard-terminal-ui
description:
  ANSI terminal status dashboard rendering for orchestrator state. Use when
  customizing dashboard layout or debugging render issues.
---

# dashboard/terminal-ui

Owns ANSI terminal rendering for the observability dashboard, including refresh cadence and snapshot formatting.

## Files

- `lib/symphony_elixir/status_dashboard.ex`: terminal dashboard GenServer and rendering helpers
