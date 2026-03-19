# Orchestrator Core

This wrapper points to the thin orchestrator composition layer in:

- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/orchestrator/runtime.ex`
- `elixir/lib/symphony_elixir/orchestrator/operations.ex`
- `elixir/lib/symphony_elixir/orchestrator/state.ex`

Responsibilities:

- GenServer startup and shutdown lifecycle
- Poll tick scheduling and poll-cycle handoff
- Dependency wiring across extracted folders
- Dashboard refreshes only when orchestrator state changes
- Callback-boundary guards for stale or malformed worker messages
