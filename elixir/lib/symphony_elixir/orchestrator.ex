defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls tracker issues and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Orchestrator.{Operations, Runtime}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, Runtime.init_state()}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = Runtime.begin_poll_check(state)
    Runtime.notify_dashboard()
    :ok = Runtime.schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = Runtime.begin_poll_check(state)
    Runtime.notify_dashboard()
    :ok = Runtime.schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state =
      state
      |> Runtime.refresh_runtime_config()
      |> Operations.maybe_dispatch()
      |> Runtime.complete_poll_check()

    Runtime.notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    state = Operations.handle_runner_down(state, ref, reason)
    Runtime.notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, state)
      when is_binary(issue_id) and is_map(runtime_info) do
    state = Operations.update_runtime_info(state, issue_id, runtime_info)
    Runtime.notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:worker_runtime_info, _issue_id, _runtime_info}, state), do: {:noreply, state}

  def handle_info({:codex_worker_update, issue_id, update}, state) do
    updated_state = Operations.handle_codex_update(state, issue_id, update)

    if updated_state != state do
      Runtime.notify_dashboard()
    end

    {:noreply, updated_state}
  end

  def handle_info({:agent_runner_dispatch_complete, issue_id}, state) do
    state = Operations.handle_dispatch_complete(state, issue_id)
    Runtime.notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case Operations.pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          Operations.handle_retry_issue(state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    Runtime.notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    Runtime.request_refresh(server)
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    Runtime.snapshot(server, timeout)
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    Runtime.handle_snapshot_call(state)
  end

  def handle_call(:request_refresh, _from, state) do
    Runtime.handle_request_refresh_call(state)
  end

  defdelegate reconcile_issue_states_for_test(issues, state), to: Operations
  defdelegate should_dispatch_issue_for_test(issue, state), to: Operations
  defdelegate revalidate_issue_for_dispatch_for_test(issue, issue_fetcher), to: Operations
  defdelegate sort_issues_for_dispatch_for_test(issues), to: Operations
  defdelegate select_worker_host_for_test(state, issue, preferred_worker_host), to: Operations

  defdelegate worker_slots_available_for_test(state, issue, preferred_worker_host \\ nil),
    to: Operations

  defdelegate transition_issue_for_dispatch_for_test(
                issue,
                update_issue_state_fun,
                fetch_issue_states_fun \\ &SymphonyElixir.Tracker.fetch_issue_states_by_ids/1
              ),
              to: Operations

  defdelegate retry_delay_for_test(attempt, metadata), to: Operations
  defdelegate handle_retry_issue_for_test(state, issue_id, attempt, metadata), to: Operations
  defdelegate resolve_dispatch_profile_for_test(issue, transition_name), to: Operations
  defdelegate resolve_dispatch_transition_for_test(issue, transition_name), to: Operations

  defdelegate persist_issue_session_for_test(running_entry, issue, worker_host, dispatch_profile),
    to: Operations

  defdelegate record_session_completion_totals_for_test(state, running_entry, result),
    to: Operations

  defdelegate terminate_running_issue_for_test(state, issue_id, cleanup_workspace),
    to: Operations
end
