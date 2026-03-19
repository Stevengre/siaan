defmodule SymphonyElixir.Dispatch.Retry do
  @moduledoc false

  import Bitwise, only: [<<<: 2]
  require Logger

  alias SymphonyElixir.{Config, StateSync}
  alias SymphonyElixir.Dispatch.Scheduler
  alias SymphonyElixir.StateSync.Issue, as: Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000

  @spec retry_delay(pos_integer(), map()) :: pos_integer()
  def retry_delay(attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  @spec schedule_issue_retry(map(), String.t(), integer() | nil, map()) :: map()
  def schedule_issue_retry(state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    retry_attempts = Map.get(state, :retry_attempts, %{})
    previous_retry = Map.get(retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    delay_type = pick_retry_delay_type(previous_retry, metadata)
    transition = pick_retry_transition(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    Map.put(
      state,
      :retry_attempts,
      Map.put(retry_attempts, issue_id, %{
        attempt: next_attempt,
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: due_at_ms,
        identifier: identifier,
        error: error,
        worker_host: worker_host,
        workspace_path: workspace_path,
        delay_type: delay_type,
        transition: transition
      })
    )
  end

  @spec pop_retry_attempt_state(map(), String.t(), reference()) ::
          {:ok, integer(), map(), map()} | :missing
  def pop_retry_attempt_state(state, issue_id, retry_token)
      when is_map(state) and is_reference(retry_token) do
    case Map.get(Map.get(state, :retry_attempts, %{}), issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          delay_type: Map.get(retry_entry, :delay_type),
          transition: Map.get(retry_entry, :transition)
        }

        updated_retry_attempts = Map.delete(Map.get(state, :retry_attempts, %{}), issue_id)
        {:ok, attempt, metadata, Map.put(state, :retry_attempts, updated_retry_attempts)}

      _ ->
        :missing
    end
  end

  @spec handle_retry_issue(map(), String.t(), non_neg_integer(), map(), keyword()) ::
          {:noreply, map()}
  def handle_retry_issue(state, issue_id, attempt, metadata, opts)
      when is_map(state) and is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and
             is_map(metadata) and is_list(opts) do
    context = %{
      active_states: Keyword.fetch!(opts, :active_states),
      terminal_states: Keyword.fetch!(opts, :terminal_states),
      release_issue_claim: Keyword.fetch!(opts, :release_issue_claim),
      cleanup_issue_workspace: Keyword.fetch!(opts, :cleanup_issue_workspace),
      dispatch_issue: Keyword.fetch!(opts, :dispatch_issue),
      dispatch_slots_available: Keyword.fetch!(opts, :dispatch_slots_available),
      worker_slots_available: Keyword.fetch!(opts, :worker_slots_available)
    }

    case StateSync.fetch_issue_states_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata, context)

      {:error, reason} ->
        Logger.warning("Retry refresh failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  @spec reconcile_stalled_running_issues(map(), keyword()) :: map()
  def reconcile_stalled_running_issues(state, opts) when is_map(state) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    terminate_running_issue = Keyword.fetch!(opts, :terminate_running_issue)

    cond do
      timeout_ms <= 0 ->
        state

      map_size(Map.get(state, :running, %{})) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(Map.get(state, :running, %{}), state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms, terminate_running_issue)
        end)
    end
  end

  @spec next_retry_attempt_from_running(map()) :: integer() | nil
  def next_retry_attempt_from_running(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  def next_retry_attempt_from_running(_running_entry), do: nil

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)

    min(
      @failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms
    )
  end

  defp handle_retry_issue_lookup(
         %Issue{} = issue,
         state,
         issue_id,
         attempt,
         metadata,
         context
       ) do
    cond do
      Scheduler.terminal_issue_state?(issue.state, context.terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        context.cleanup_issue_workspace.(issue.identifier, metadata[:worker_host])
        {:noreply, context.release_issue_claim.(state, issue_id)}

      Scheduler.retry_candidate_issue?(issue, context.active_states, context.terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata, context)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, context.release_issue_claim.(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(
         nil,
         state,
         issue_id,
         _attempt,
         _metadata,
         context
       ) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, context.release_issue_claim.(state, issue_id)}
  end

  defp handle_active_retry(state, issue, attempt, metadata, context) do
    if Scheduler.retry_candidate_issue?(issue, context.active_states, context.terminal_states) and
         context.dispatch_slots_available.(issue, state) and
         context.worker_slots_available.(state, issue, metadata[:worker_host]) do
      {:noreply, context.dispatch_issue.(state, issue, attempt, metadata)}
    else
      Logger.debug("No available slots for retrying issue_id=#{issue.id} issue_identifier=#{issue.identifier}; retrying again")

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

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms, terminate_running_issue) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if Map.get(running_entry, :busy, true) and is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue.(issue_id, false)
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

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
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
end
