defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls tracker issues and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config
  alias SymphonyElixir.Dispatch.{Retry, Scheduler}
  alias SymphonyElixir.DispatchLifecycle
  alias SymphonyElixir.SessionStats
  alias SymphonyElixir.SessionTracker.Metering
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TrackerIssue, as: Issue
  alias SymphonyElixir.Workspace.Provisioner, as: Workspace

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
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
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        busy? = Map.get(running_entry, :busy, true)
        state = maybe_record_runner_completion(state, running_entry, reason, busy?)

        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              handle_normal_runner_down(state, running_entry, issue_id, session_id, busy?)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                transition: "retry_continuation"
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:agent_runner_dispatch_complete, issue_id}, %{running: running} = state) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        state = record_session_completion_totals(state, running_entry, "completed")
        updated_running_entry = mark_runner_idle(running_entry)

        state =
          state
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :continuation,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            transition: "retry_continuation"
          })

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_normal_runner_down(state, running_entry, issue_id, session_id, true) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, 1, %{
      identifier: running_entry.identifier,
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      transition: "retry_continuation"
    })
  end

  defp handle_normal_runner_down(state, _running_entry, issue_id, _session_id, false) do
    release_issue_claim(state, issue_id)
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

  defp maybe_record_runner_completion(state, running_entry, reason, true) do
    result = if(reason == :normal, do: "completed", else: "agent_exit")
    record_session_completion_totals(state, running_entry, result)
  end

  defp maybe_record_runner_completion(state, _running_entry, _reason, false), do: state

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         state <- reconcile_tracker_watch_states(state),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in runtime config")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project slug missing in runtime config")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in runtime config")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in runtime config: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid runtime config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing runtime config at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse runtime config: legacy markdown front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse runtime config: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch tracker issues: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_tracker_watch_states(%State{} = state) do
    case Tracker.reconcile_watch_states() do
      :ok ->
        state

      {:error, reason} ->
        Logger.debug("Failed to reconcile tracker watch states: #{inspect(reason)}")
        state
    end
  end

  defp watch_state_set do
    (Config.settings!().tracker.watch_states || [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp keep_live_session_state?(state_name) when is_binary(state_name) do
    MapSet.member?(watch_state_set(), normalize_issue_state(state_name))
  end

  defp keep_idle_watch_state_runner?(%State{} = state, %Issue{id: issue_id, state: state_name})
       when is_binary(issue_id) and is_binary(state_name) do
    keep_live_session_state?(state_name) and idle_running_entry?(Map.get(state.running, issue_id))
  end

  defp keep_idle_watch_state_runner?(_state, _issue), do: false

  defp idle_running_entry?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :busy, true) == false
  end

  defp idle_running_entry?(_running_entry), do: false

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    Scheduler.should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    Scheduler.sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, issue, preferred_worker_host) do
    Scheduler.select_worker_host(state, issue, preferred_worker_host)
  end

  @doc false
  @spec worker_slots_available_for_test(term(), term(), String.t() | nil) :: boolean()
  def worker_slots_available_for_test(%State{} = state, issue, preferred_worker_host \\ nil) do
    Scheduler.worker_slots_available?(state, issue, preferred_worker_host)
  end

  @doc false
  @spec transition_issue_for_dispatch_for_test(
          Issue.t(),
          (String.t(), String.t() -> term()),
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})
        ) ::
          {:ok, Issue.t()} | {:error, term()}
  def transition_issue_for_dispatch_for_test(
        %Issue{} = issue,
        update_issue_state_fun,
        fetch_issue_states_fun \\ &Tracker.fetch_issue_states_by_ids/1
      )
      when is_function(update_issue_state_fun, 2) and is_function(fetch_issue_states_fun, 1) do
    transition_issue_for_dispatch(issue, update_issue_state_fun, fetch_issue_states_fun)
  end

  @doc false
  @spec retry_delay_for_test(pos_integer(), map()) :: pos_integer()
  def retry_delay_for_test(attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    Retry.retry_delay(attempt, metadata)
  end

  @doc false
  @spec handle_retry_issue_for_test(State.t(), String.t(), non_neg_integer(), map()) ::
          {:noreply, State.t()}
  def handle_retry_issue_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata)
  end

  @doc false
  @spec resolve_dispatch_profile_for_test(Issue.t(), String.t()) :: map()
  def resolve_dispatch_profile_for_test(%Issue{} = issue, transition_name)
      when is_binary(transition_name) do
    resolve_dispatch_profile(issue, transition_name)
  end

  @spec resolve_dispatch_transition_for_test(Issue.t(), String.t() | nil) :: String.t()
  def resolve_dispatch_transition_for_test(%Issue{} = issue, transition_name) do
    resolve_dispatch_transition(issue, transition_name)
  end

  @doc false
  @spec persist_issue_session_for_test(map(), Issue.t(), String.t() | nil, map() | nil) :: :ok
  def persist_issue_session_for_test(
        running_entry,
        %Issue{} = issue,
        worker_host,
        dispatch_profile
      )
      when is_map(running_entry) and (is_map(dispatch_profile) or is_nil(dispatch_profile)) do
    record_issue_session(running_entry, issue, worker_host, dispatch_profile)
  end

  @doc false
  @spec record_session_completion_totals_for_test(State.t(), map(), String.t()) :: State.t()
  def record_session_completion_totals_for_test(%State{} = state, running_entry, result)
      when is_map(running_entry) and is_binary(result) do
    record_session_completion_totals(state, running_entry, result)
  end

  @doc false
  @spec terminate_running_issue_for_test(State.t(), String.t(), boolean()) :: State.t()
  def terminate_running_issue_for_test(%State{} = state, issue_id, cleanup_workspace)
      when is_binary(issue_id) and is_boolean(cleanup_workspace) do
    terminate_running_issue(state, issue_id, cleanup_workspace)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) or keep_idle_watch_state_runner?(state, issue) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = maybe_record_terminated_session(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) and Map.get(running_entry, :persistent_runner, false) do
          AgentRunner.stop(pid)
        else
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    Retry.reconcile_stalled_running_issues(state,
      timeout_ms: Config.settings!().codex.stall_timeout_ms,
      terminate_running_issue: &terminate_running_issue/3
    )
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if Map.get(running_entry, :busy, true) and is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        transition: "stall_recovery"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    result =
      case Process.whereis(SymphonyElixir.TaskSupervisor) do
        task_supervisor when is_pid(task_supervisor) ->
          try do
            Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
          catch
            :exit, _reason -> {:error, :supervisor_unavailable}
          end

        _ ->
          {:error, :supervisor_unavailable}
      end

    case result do
      :ok ->
        :ok

      {:error, :supervisor_unavailable} ->
        Process.exit(pid, :shutdown)

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Scheduler.sort_issues_for_dispatch(issues)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    Scheduler.should_dispatch_issue?(issue, state, active_states, terminal_states)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp dispatchable_running_entry?(nil), do: true

  defp dispatchable_running_entry?(running_entry) when is_map(running_entry) do
    not Map.get(running_entry, :busy, true)
  end

  defp dispatchable_running_entry?(_running_entry), do: false

  defp reusable_running_entry?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :persistent_runner, false) and
      is_pid(Map.get(running_entry, :pid)) and not Map.get(running_entry, :busy, true)
  end

  defp reusable_running_entry?(_running_entry), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}} = running_entry} ->
        normalize_issue_state(state_name) == normalized_state and
          Map.get(running_entry, :busy, false)

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}, terminal_states)
       when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    Scheduler.terminal_issue_state?(state_name, terminal_states)
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    Scheduler.active_issue_state?(state_name, active_states)
  end

  defp normalize_issue_state(state_name) when is_binary(state_name),
    do: Scheduler.normalize_issue_state(state_name)

  defp terminal_state_set do
    Scheduler.terminal_state_set()
  end

  defp active_state_set do
    Scheduler.active_state_set()
  end

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         transition_name \\ nil
       ) do
    case revalidate_issue_for_dispatch(
           issue,
           &Tracker.fetch_issue_states_by_ids/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        dispatch_transition = resolve_dispatch_transition(refreshed_issue, transition_name)

        case transition_issue_for_dispatch(
               refreshed_issue,
               &Tracker.update_issue_state/2,
               &Tracker.fetch_issue_states_by_ids/1
             ) do
          {:ok, %Issue{} = dispatch_issue} ->
            do_dispatch_issue(
              state,
              dispatch_issue,
              attempt,
              preferred_worker_host,
              dispatch_transition
            )

          {:error, reason} ->
            Logger.warning("Skipping dispatch; issue state transition failed for #{issue_context(refreshed_issue)}: #{inspect(reason)}")

            state
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")

        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")

        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, transition_name) do
    recipient = self()
    dispatch_profile = resolve_dispatch_profile(issue, transition_name)

    case Map.get(state.running, issue.id) do
      %{busy: false} = running_entry ->
        reuse_live_runner(state, running_entry, issue, attempt, dispatch_profile)

      _ ->
        case select_worker_host(state, issue, preferred_worker_host) do
          :no_worker_capacity ->
            Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")

            state

          worker_host ->
            spawn_issue_on_worker_host(
              state,
              issue,
              attempt,
              recipient,
              worker_host,
              dispatch_profile
            )
        end
    end
  end

  defp spawn_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         dispatch_profile
       ) do
    agent_opts = [
      attempt: attempt,
      worker_host: worker_host,
      codex_command: dispatch_profile.codex_command,
      issue_turn_count: dispatch_profile.issue_turn_count
    ]

    case AgentRunner.start(issue, recipient, agent_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info(
          "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"} execution_profile=#{dispatch_profile.profile_name} transition=#{dispatch_profile.transition_name} reuse=#{dispatch_profile.session_reuse_decision}"
        )

        running_entry =
          prepare_running_entry_for_dispatch(
            %{
              issue_id: issue.id,
              pid: pid,
              ref: ref,
              persistent_runner: true,
              worker_host: worker_host,
              workspace_path: nil,
              codex_thread_id: dispatch_profile.codex_thread_id,
              physical_session_count: dispatch_profile.physical_session_count,
              codex_app_server_pid: nil,
              siaan_version: SessionStats.app_version(),
              codex_model: SessionStats.configured_model(dispatch_profile.codex_command)
            },
            issue,
            attempt,
            dispatch_profile,
            false
          )

        :ok = record_issue_session(running_entry, issue, worker_host, dispatch_profile)
        AgentRunner.dispatch_turn(pid, issue, dispatch_opts_for_profile(dispatch_profile, false))

        running =
          Map.put(state.running, issue.id, running_entry)

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          transition: dispatch_profile.transition_name
        })
    end
  end

  defp reuse_live_runner(%State{} = state, running_entry, issue, attempt, dispatch_profile) do
    pid = Map.get(running_entry, :pid)
    worker_host = Map.get(running_entry, :worker_host)

    Logger.info(
      "Reusing live agent runner for #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"} execution_profile=#{dispatch_profile.profile_name} transition=#{dispatch_profile.transition_name} reuse=#{dispatch_profile.session_reuse_decision}"
    )

    updated_running_entry =
      running_entry
      |> prepare_running_entry_for_dispatch(issue, attempt, dispatch_profile, true)

    :ok = record_issue_session(updated_running_entry, issue, worker_host, dispatch_profile)
    AgentRunner.dispatch_turn(pid, issue, dispatch_opts_for_profile(dispatch_profile, true))

    %{
      state
      | running: Map.put(state.running, issue.id, updated_running_entry),
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp dispatch_opts_for_profile(dispatch_profile, reuse_physical_session?) do
    [
      issue_turn_count: dispatch_profile.issue_turn_count,
      reuse_physical_session: reuse_physical_session?
    ]
  end

  defp prepare_running_entry_for_dispatch(
         running_entry,
         issue,
         attempt,
         dispatch_profile,
         true
       )
       when is_map(running_entry) do
    do_prepare_running_entry_for_dispatch(
      running_entry,
      issue,
      attempt,
      dispatch_profile,
      "reused_physical_session",
      nil
    )
  end

  defp prepare_running_entry_for_dispatch(
         running_entry,
         issue,
         attempt,
         dispatch_profile,
         false
       )
       when is_map(running_entry) do
    do_prepare_running_entry_for_dispatch(
      running_entry,
      issue,
      attempt,
      dispatch_profile,
      dispatch_profile.physical_session_reuse_decision,
      dispatch_profile.physical_session_fallback_reason
    )
  end

  defp do_prepare_running_entry_for_dispatch(
         running_entry,
         issue,
         attempt,
         dispatch_profile,
         physical_session_reuse_decision,
         physical_session_fallback_reason
       ) do
    running_entry
    |> Map.put(:busy, true)
    |> Map.put(:completion_recorded, false)
    |> Map.put(:issue, issue)
    |> Map.put(:identifier, issue.identifier)
    |> Map.put(:session_id, nil)
    |> Map.put(:execution_profile, dispatch_profile.profile_name)
    |> Map.put(:execution_transition, dispatch_profile.transition_name)
    |> Map.put(:session_reuse_policy, dispatch_profile.session_reuse_policy)
    |> Map.put(:session_reuse_decision, dispatch_profile.session_reuse_decision)
    |> Map.put(:physical_session_reuse_decision, physical_session_reuse_decision)
    |> Map.put(:physical_session_fallback_reason, physical_session_fallback_reason)
    |> Map.put(:issue_session_id, dispatch_profile.issue_session_id)
    |> Map.put(:issue_session_turn_count, dispatch_profile.issue_turn_count)
    |> Map.put(:codex_command, dispatch_profile.codex_command)
    |> Map.put(:retry_attempt, normalize_retry_attempt(attempt))
    |> Map.put(:last_codex_message, nil)
    |> Map.put(:last_codex_timestamp, nil)
    |> Map.put(:last_codex_event, nil)
    |> Map.put(:codex_input_tokens, 0)
    |> Map.put(:codex_output_tokens, 0)
    |> Map.put(:codex_total_tokens, 0)
    |> Map.put(:codex_last_reported_input_tokens, 0)
    |> Map.put(:codex_last_reported_output_tokens, 0)
    |> Map.put(:codex_last_reported_total_tokens, 0)
    |> Map.put(:turn_count, 0)
    |> Map.put(:started_at, DateTime.utc_now())
  end

  defp mark_runner_idle(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.put(:busy, false)
    |> Map.put(:completion_recorded, true)
    |> Map.put(:session_id, nil)
    |> Map.put(:last_codex_message, nil)
    |> Map.put(:last_codex_event, nil)
  end

  defp resolve_dispatch_transition(%Issue{state: issue_state} = issue, explicit_transition)
       when is_binary(issue_state) do
    DispatchLifecycle.resolve_dispatch_transition(issue, explicit_transition)
  end

  defp resolve_dispatch_transition(_issue, explicit_transition) when is_binary(explicit_transition) do
    DispatchLifecycle.resolve_dispatch_transition(nil, explicit_transition)
  end

  defp resolve_dispatch_transition(_issue, _explicit_transition),
    do: DispatchLifecycle.resolve_dispatch_transition(nil, nil)

  defp resolve_dispatch_profile(%Issue{} = issue, transition_name) do
    existing_issue_session = SessionStats.load_issue_session(issue.id)

    default_profile_name =
      DispatchLifecycle.default_profile_name_for_transition(
        issue,
        transition_name,
        existing_issue_session
      )

    profile_name =
      DispatchLifecycle.pick_profile_name(
        existing_issue_session,
        transition_name,
        default_profile_name
      )

    profile = Config.execution_profile(profile_name)

    issue_session =
      build_issue_session(
        issue,
        existing_issue_session,
        profile_name,
        profile,
        transition_name
      )

    %{
      transition_name: transition_name,
      profile_name: profile_name,
      session_reuse_policy: profile.session_reuse,
      session_reuse_decision: issue_session["session_reuse_decision"],
      physical_session_reuse_decision: issue_session["physical_session_reuse_decision"],
      physical_session_fallback_reason: issue_session["physical_session_fallback_reason"],
      issue_session_id: issue_session["issue_session_id"],
      issue_turn_count: Map.get(issue_session, "issue_session_turn_count", 0),
      physical_session_count: Map.get(issue_session, "physical_session_count", 0),
      codex_thread_id: Map.get(issue_session, "physical_session_id"),
      codex_command: profile.codex_command,
      issue_session: issue_session
    }
  end

  defp build_issue_session(issue, existing_issue_session, profile_name, profile, transition_name) do
    reuse_existing? =
      profile.session_reuse == "reuse_issue_session" and is_map(existing_issue_session) and
        not DispatchLifecycle.initial_dispatch_transition_name?(transition_name)

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {base_session, session_reuse_decision} =
      if reuse_existing? do
        initialize_issue_session(existing_issue_session, issue.id)
      else
        {new_issue_session(issue.id), "started_new_issue_session"}
      end

    {physical_session_reuse_decision, physical_session_fallback_reason, physical_session_id} =
      resolve_physical_session_reuse(existing_issue_session, profile, transition_name)

    Map.merge(base_session, %{
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "execution_profile" => profile_name,
      "execution_transition" => transition_name,
      "session_reuse_policy" => profile.session_reuse,
      "session_reuse_decision" => session_reuse_decision,
      "physical_session_reuse_decision" => physical_session_reuse_decision,
      "physical_session_fallback_reason" => physical_session_fallback_reason,
      "codex_command" => profile.codex_command,
      "model" => SessionStats.configured_model(profile.codex_command),
      "physical_session_id" => physical_session_id,
      "updated_at" => now,
      "created_at" => Map.get(base_session, "created_at", now)
    })
    |> Map.delete("pending_transition")
  end

  defp initialize_issue_session(existing_issue_session, issue_id)
       when is_map(existing_issue_session) do
    existing_issue_session_id =
      normalized_issue_session_id(existing_issue_session["issue_session_id"])

    session_reuse_decision =
      if is_binary(existing_issue_session_id) do
        "reused_issue_session"
      else
        "started_new_issue_session"
      end

    issue_session =
      existing_issue_session
      |> Map.put("issue_session_id", existing_issue_session_id || issue_session_id(issue_id))
      |> Map.put_new("issue_session_turn_count", 0)
      |> Map.put_new("physical_session_count", 0)

    {issue_session, session_reuse_decision}
  end

  defp new_issue_session(issue_id) when is_binary(issue_id) do
    %{
      "issue_session_id" => issue_session_id(issue_id),
      "issue_session_turn_count" => 0,
      "physical_session_count" => 0
    }
  end

  defp normalized_issue_session_id(issue_session_id) when is_binary(issue_session_id) do
    case String.trim(issue_session_id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalized_issue_session_id(_issue_session_id), do: nil

  defp resolve_physical_session_reuse(existing_issue_session, profile, transition_name) do
    if physical_session_reuse_allowed?(profile, transition_name) do
      case existing_physical_session_id(existing_issue_session) do
        thread_id when is_binary(thread_id) ->
          {"started_new_physical_session", "ephemeral_app_server_lifecycle", nil}

        _ ->
          {"started_new_physical_session", "missing_previous_physical_session_id", nil}
      end
    else
      {"started_new_physical_session", nil, nil}
    end
  end

  defp physical_session_reuse_allowed?(profile, transition_name) do
    profile.session_reuse == "reuse_issue_session" and transition_name == "review_to_in_progress"
  end

  defp existing_physical_session_id(%{"physical_session_id" => thread_id})
       when is_binary(thread_id) and thread_id != "",
       do: thread_id

  defp existing_physical_session_id(_existing_issue_session), do: nil

  defp record_issue_session(running_entry, issue, worker_host, dispatch_profile) do
    case persist_issue_session(running_entry, issue, worker_host, dispatch_profile) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Unable to persist issue session for #{issue_context(issue)} transition=#{Map.get(running_entry, :execution_transition)} worker_host=#{worker_host || Map.get(running_entry, :worker_host) || "local"}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp persist_issue_session(running_entry, issue, worker_host, dispatch_profile) do
    issue_session =
      if is_map(dispatch_profile) do
        dispatch_profile.issue_session
      else
        SessionStats.load_issue_session(Map.get(running_entry, :issue_id)) || %{}
      end

    issue_identifier =
      case issue do
        %Issue{identifier: identifier} -> identifier
        _ -> Map.get(running_entry, :identifier)
      end

    issue_id =
      case issue do
        %Issue{id: issue_id} -> issue_id
        _ -> Map.get(running_entry, :issue_id)
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    issue_session
    |> Map.merge(%{
      "issue_id" => issue_id,
      "issue_identifier" => issue_identifier,
      "issue_session_id" => Map.get(running_entry, :issue_session_id),
      "execution_profile" => Map.get(running_entry, :execution_profile),
      "execution_transition" => Map.get(running_entry, :execution_transition),
      "session_reuse_policy" => Map.get(running_entry, :session_reuse_policy),
      "session_reuse_decision" => Map.get(running_entry, :session_reuse_decision),
      "physical_session_reuse_decision" => Map.get(running_entry, :physical_session_reuse_decision),
      "physical_session_fallback_reason" => Map.get(running_entry, :physical_session_fallback_reason),
      "codex_command" => Map.get(running_entry, :codex_command),
      "model" => Map.get(running_entry, :codex_model),
      "issue_session_turn_count" => Map.get(running_entry, :issue_session_turn_count, 0),
      "physical_session_count" => Map.get(running_entry, :physical_session_count, 0),
      "physical_session_id" => Map.get(running_entry, :codex_thread_id),
      "last_session_id" => Map.get(running_entry, :session_id),
      "last_worker_host" => worker_host || Map.get(running_entry, :worker_host),
      "last_workspace_path" => Map.get(running_entry, :workspace_path),
      "updated_at" => now,
      "created_at" => Map.get(issue_session, "created_at", now)
    })
    |> Map.delete("pending_transition")
    |> SessionStats.save_issue_session()
  end

  defp issue_session_id(issue_id) do
    suffix = System.unique_integer([:positive, :monotonic])
    "issue-session-#{issue_id}-#{suffix}"
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp transition_issue_for_dispatch(
         %Issue{state: issue_state} = issue,
         update_issue_state_fun,
         fetch_issue_states_fun
       )
       when is_binary(issue_state) and is_function(update_issue_state_fun, 2) and
              is_function(fetch_issue_states_fun, 1) do
    DispatchLifecycle.prepare_issue_for_dispatch(
      issue,
      update_issue_state_fun,
      fetch_issue_states_fun
    )
  end

  defp transition_issue_for_dispatch(issue, _update_issue_state_fun, _fetch_issue_states_fun),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    Retry.schedule_issue_retry(state, issue_id, attempt, metadata)
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token)
       when is_reference(retry_token) do
    Retry.pop_retry_attempt_state(state, issue_id, retry_token)
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    Retry.handle_retry_issue(state, issue_id, attempt, metadata,
      active_states: active_state_set(),
      terminal_states: terminal_state_set(),
      release_issue_claim: &release_issue_claim/2,
      cleanup_issue_workspace: &cleanup_issue_workspace/2,
      dispatch_issue: fn retry_state, issue, retry_attempt, retry_metadata ->
        dispatch_issue(
          retry_state,
          issue,
          retry_attempt,
          retry_metadata[:worker_host],
          retry_metadata[:transition]
        )
      end,
      dispatch_slots_available: &dispatch_slots_available?/2,
      worker_slots_available: &worker_slots_available?/3
    )
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, issue, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata[:transition])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    Retry.retry_delay(attempt, metadata)
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_delay_type(previous_retry, metadata) do
    metadata[:delay_type] || Map.get(previous_retry, :delay_type)
  end

  defp pick_retry_transition(previous_retry, metadata) do
    metadata[:transition] || Map.get(previous_retry, :transition)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, issue, preferred_worker_host) do
    Scheduler.select_worker_host(state, issue, preferred_worker_host)
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host)
       when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host} = running_entry} ->
        Map.get(running_entry, :busy, true)

      _ ->
        false
    end)
  end

  defp worker_slots_available?(%State{} = state, issue) do
    Scheduler.worker_slots_available?(state, issue)
  end

  defp worker_slots_available?(%State{} = state, issue, preferred_worker_host) do
    Scheduler.worker_slots_available?(state, issue, preferred_worker_host)
  end

  defp dispatch_worker_host_available?(%State{} = state, issue, preferred_worker_host) do
    case Map.get(state.running, issue.id) do
      %{worker_host: worker_host} = running_entry ->
        if reusable_running_entry?(running_entry) do
          reusable_worker_host_available?(state, issue, worker_host)
        else
          select_worker_host(state, issue, preferred_worker_host) != :no_worker_capacity
        end

      _ ->
        select_worker_host(state, issue, preferred_worker_host) != :no_worker_capacity
    end
  end

  defp reusable_worker_host_available?(_state, %{project_runtime: runtime}, _worker_host)
       when runtime in ["local", :local],
       do: true

  defp reusable_worker_host_available?(%State{} = state, _issue, worker_host)
       when is_binary(worker_host),
       do: worker_host_slots_available?(state, worker_host)

  defp reusable_worker_host_available?(_state, _issue, _worker_host), do: true

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp local_runtime_project_slots_available?(running, %{
         project_runtime: runtime,
         project_dir: project_dir
       })
       when runtime in ["local", :local] and is_map(running) and is_binary(project_dir) do
    project_dir_key = local_runtime_project_dir_key(project_dir)

    Enum.all?(running, fn
      {_issue_id,
       %{issue: %Issue{project_runtime: running_runtime, project_dir: running_project_dir}} =
           running_entry}
      when running_runtime in ["local", :local] and is_binary(running_project_dir) ->
        not Map.get(running_entry, :busy, true) or
          local_runtime_project_dir_key(running_project_dir) != project_dir_key

      _ ->
        true
    end)
  end

  defp local_runtime_project_slots_available?(_running, _issue), do: true

  defp local_runtime_project_dir_key(project_dir) when is_binary(project_dir) do
    project_dir
    |> Path.expand()
    |> String.trim_trailing("/")
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    Scheduler.available_slots(state)
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

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

  @impl true
  def handle_call(:snapshot, _from, state) do
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

  def handle_call(:request_refresh, _from, state) do
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

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    Metering.integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update)
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp physical_session_id_for_update(_existing, %{thread_id: thread_id})
       when is_binary(thread_id),
       do: thread_id

  defp physical_session_id_for_update(existing, _update), do: existing

  defp physical_session_reuse_decision_for_update(_existing, %{
         physical_session_reuse_decision: decision
       })
       when is_binary(decision),
       do: decision

  defp physical_session_reuse_decision_for_update(existing, _update), do: existing

  defp physical_session_fallback_reason_for_update(_existing, %{
         physical_session_fallback_reason: reason
       })
       when is_binary(reason),
       do: reason

  defp physical_session_fallback_reason_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp physical_session_count_for_update(existing_count, existing_thread_id, %{
         event: :session_started,
         thread_id: thread_id
       })
       when is_integer(existing_count) and is_binary(thread_id) do
    if thread_id == existing_thread_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp physical_session_count_for_update(existing_count, _existing_thread_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp physical_session_count_for_update(_existing_count, _existing_thread_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
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

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp maybe_record_terminated_session(state, %{completion_recorded: true, busy: false}),
    do: state

  defp maybe_record_terminated_session(state, running_entry) when is_map(running_entry) do
    record_session_completion_totals(state, running_entry, "terminated")
  end

  defp record_session_completion_totals(state, running_entry, result)
       when is_map(running_entry) do
    runtime_seconds = Metering.running_seconds(running_entry.started_at, DateTime.utc_now())
    completed_record = SessionStats.build_completed_record(running_entry, result)

    :ok =
      record_issue_session(
        running_entry,
        Map.get(running_entry, :issue),
        Map.get(running_entry, :worker_host),
        nil
      )

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    case SessionStats.append_history_record(completed_record) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to persist session stats: #{inspect(reason)}")
    end

    %{
      state
      | codex_totals: codex_totals,
        completed_runs:
          [completed_record | Map.get(state, :completed_runs, [])]
          |> Enum.take(SessionStats.recent_history_limit())
    }
  end

  defp record_session_completion_totals(state, _running_entry, _result), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    Scheduler.retry_candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    Scheduler.dispatch_slots_available?(issue, state)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case Metering.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    Metering.apply_token_delta(codex_totals, token_delta)
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
