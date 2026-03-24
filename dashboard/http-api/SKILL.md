---
name: dashboard-http-api
description:
  Observability HTTP API routes and JSON presentation. Use when changing the
  dashboard status API surface or presenter output.
---

# dashboard/http-api

Owns the observability HTTP API surface and JSON presentation for dashboard consumers.

## Files

- `lib/symphony_elixir_web/router.ex`: observability router entrypoints
- `lib/symphony_elixir_web/controllers/observability_api_controller.ex`: REST API controller
- `lib/symphony_elixir_web/presenter.ex`: JSON payload presenter
