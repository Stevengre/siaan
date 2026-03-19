defmodule SymphonyElixir.Orchestrator.State do
  @moduledoc """
  Runtime state for the orchestrator polling loop.
  """

  defstruct [
    :poll_interval_ms,
    :max_concurrent_agents,
    :next_poll_due_at_ms,
    :poll_check_in_progress,
    :tick_timer_ref,
    :tick_token,
    running: %{},
    completed: MapSet.new(),
    completed_runs: [],
    claimed: MapSet.new(),
    retry_attempts: %{},
    codex_totals: nil,
    codex_rate_limits: nil
  ]

  @type t :: %__MODULE__{}
end
