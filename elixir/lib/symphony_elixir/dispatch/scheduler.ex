defmodule SymphonyElixir.Dispatch.Scheduler do
  @moduledoc false

  alias SymphonyElixir.{Config, StateSync}
  alias SymphonyElixir.StateSync.Issue, as: Issue

  @spec sort_issues_for_dispatch([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  @spec should_dispatch_issue?(Issue.t(), map(), MapSet.t(), MapSet.t()) :: boolean()
  def should_dispatch_issue?(
        %Issue{} = issue,
        %{running: running, claimed: claimed} = state,
        active_states,
        terminal_states
      ) do
    running_entry = Map.get(running, issue.id)

    candidate_issue?(issue, active_states, terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states) and
      (!MapSet.member?(claimed, issue.id) or reusable_running_entry?(running_entry)) and
      dispatchable_running_entry?(running_entry) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state, issue)
  end

  def should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  @spec available_slots(map()) :: non_neg_integer()
  def available_slots(state) when is_map(state) do
    busy_count =
      state
      |> Map.get(:running, %{})
      |> Enum.count(fn
        {_issue_id, running_entry} -> Map.get(running_entry, :busy, true)
      end)

    max(
      (Map.get(state, :max_concurrent_agents) || Config.settings!().agent.max_concurrent_agents) -
        busy_count,
      0
    )
  end

  @spec dispatch_slots_available?(Issue.t(), map()) :: boolean()
  def dispatch_slots_available?(%Issue{} = issue, %{running: _running} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  @spec select_worker_host(map(), map(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host(_state, %{project_runtime: runtime}, _preferred_worker_host)
      when runtime in ["local", :local],
      do: nil

  def select_worker_host(state, _issue, preferred_worker_host) when is_map(state) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  @spec worker_slots_available?(map(), map(), String.t() | nil) :: boolean()
  def worker_slots_available?(state, issue, preferred_worker_host \\ nil) when is_map(state) do
    dispatch_worker_host_available?(state, issue, preferred_worker_host) and
      local_runtime_project_slots_available?(Map.get(state, :running, %{}), issue)
  end

  @spec candidate_issue?(Issue.t(), MapSet.t(), MapSet.t()) :: boolean()
  def candidate_issue?(
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

  def candidate_issue?(_issue, _active_states, _terminal_states), do: false

  @spec issue_blocked_by_non_terminal?(Issue.t(), MapSet.t()) :: boolean()
  def issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}, terminal_states)
      when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  def issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  @spec retry_candidate_issue?(Issue.t(), MapSet.t(), MapSet.t()) :: boolean()
  def retry_candidate_issue?(%Issue{} = issue, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  @spec terminal_issue_state?(String.t(), MapSet.t()) :: boolean()
  def terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  def terminal_issue_state?(_state_name, _terminal_states), do: false

  @spec active_issue_state?(String.t(), MapSet.t()) :: boolean()
  def active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  def active_issue_state?(_state_name, _active_states), do: false

  @spec active_state_set() :: MapSet.t()
  def active_state_set do
    StateSync.active_states()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec terminal_state_set() :: MapSet.t()
  def terminal_state_set do
    StateSync.terminal_states()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

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

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(Map.get(state, :running, %{}), host), index}
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

  defp dispatch_worker_host_available?(state, issue, preferred_worker_host) do
    case Map.get(Map.get(state, :running, %{}), issue.id) do
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

  defp reusable_worker_host_available?(state, _issue, worker_host)
       when is_binary(worker_host),
       do: worker_host_slots_available?(state, worker_host)

  defp reusable_worker_host_available?(_state, _issue, _worker_host), do: true

  defp worker_host_slots_available?(state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(Map.get(state, :running, %{}), worker_host) < limit

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
end
