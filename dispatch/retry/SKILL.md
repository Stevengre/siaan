# Dispatch Retry

This wrapper points to the extracted retry implementation in
`elixir/lib/symphony_elixir/dispatch/retry.ex`.

Responsibilities:

- Exponential backoff
- Continuation retry timing
- Stall detection and recovery
- Retry state bookkeeping
