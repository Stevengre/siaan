defmodule SymphonyElixir.Orchestrator.Runtime do
  @moduledoc false

  require Logger

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.SessionStats
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TrackerIssue, as: Issue

  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec init_state() :: State.t()
  def init_state do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    terminate_lingering_persistent_runners()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      completed_runs:
        SessionStats.load_recent_history()
        |> Enum.reverse(),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    schedule_tick(state, 0)
  end

  @spec begin_poll_check(State.t()) :: State.t()
  def begin_poll_check(%State{} = state) do
    state
    |> refresh_runtime_config()
    |> Map.put(:poll_check_in_progress, true)
    |> Map.put(:next_poll_due_at_ms, nil)
    |> Map.put(:tick_timer_ref, nil)
    |> Map.put(:tick_token, nil)
  end

  @spec complete_poll_check(State.t()) :: State.t()
  def complete_poll_check(%State{} = state) do
    state
    |> schedule_tick(state.poll_interval_ms)
    |> Map.put(:poll_check_in_progress, false)
  end

  @spec refresh_runtime_config(State.t()) :: State.t()
  def refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  @spec schedule_tick(State.t(), non_neg_integer()) :: State.t()
  def schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  @spec schedule_poll_cycle_start() :: :ok
  def schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  @spec notify_dashboard() :: :ok
  def notify_dashboard do
    StatusDashboard.notify_update()
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @spec handle_snapshot_call(State.t()) :: {:reply, map(), State.t()}
  def handle_snapshot_call(%State{} = state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        stats = SessionStats.build_running_summary(metadata)

        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          issue_session_id: stats.issue_session_id,
          execution_profile: stats.execution_profile,
          execution_transition: stats.execution_transition,
          session_reuse_policy: stats.session_reuse_policy,
          session_reuse_decision: stats.session_reuse_decision,
          physical_session_reuse_decision: stats.physical_session_reuse_decision,
          physical_session_fallback_reason: stats.physical_session_fallback_reason,
          physical_session_id: stats.physical_session_id,
          physical_session_count: stats.physical_session_count,
          issue_session_turn_count: stats.issue_session_turn_count,
          siaan_version: stats.siaan_version,
          codex_model: stats.model,
          repo_head_sha: stats.repo_head_sha,
          repo_branch: stats.repo_branch,
          pricing_model: stats.pricing_model,
          pricing_source: stats.pricing_source,
          estimated_cost_usd: stats.estimated_cost_usd,
          estimated_input_cost_usd: stats.estimated_input_cost_usd,
          estimated_output_cost_usd: stats.estimated_output_cost_usd,
          cost_estimate_available: stats.cost_estimate_available,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       completed_runs: state.completed_runs,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  @spec handle_request_refresh_call(State.t()) :: {:reply, map(), State.t()}
  def handle_request_refresh_call(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp terminate_lingering_persistent_runners do
    case Process.whereis(SymphonyElixir.AgentRunnerSupervisor) do
      pid when is_pid(pid) ->
        lingering_children =
          SymphonyElixir.AgentRunnerSupervisor
          |> DynamicSupervisor.which_children()
          |> Enum.flat_map(fn
            {_id, child_pid, :worker, [AgentRunner]} when is_pid(child_pid) -> [child_pid]
            _other -> []
          end)

        if lingering_children != [] do
          Logger.warning("Orchestrator restart detected with lingering persistent runners; terminating #{length(lingering_children)} runner(s)")

          Enum.each(lingering_children, &AgentRunner.stop/1)
        end

      _ ->
        :ok
    end
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            SymphonyElixir.Workspace.remove_issue_workspaces(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0
end
