# Dispatch Scheduler

This wrapper points to the extracted scheduler implementation in
`elixir/lib/symphony_elixir/dispatch/scheduler.ex`.

Responsibilities:

- Concurrency slot accounting
- Priority sorting
- Dispatch eligibility checks
- Worker host selection and capacity limits
