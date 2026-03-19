defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  require Logger

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, DispatchLifecycle}
  alias SymphonyElixir.GitHub.{Client, Issue}
  alias SymphonyElixir.TrackerIssue

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, issues} <- client_module().fetch_candidate_issues() do
      {:ok, to_tracker_issues(issues)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- client_module().fetch_issues_by_states(states) do
      {:ok, to_tracker_issues(issues)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    with {:ok, issues} <- client_module().fetch_issue_states_by_ids(issue_ids) do
      {:ok, to_tracker_issues(issues)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    client_module().update_issue_state(issue_id, state_name)
  end

  @spec active_states() :: [String.t()]
  def active_states, do: Config.settings!().tracker.active_states || []

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: Config.settings!().tracker.terminal_states || []

  @spec dispatch_target_state(TrackerIssue.t() | String.t() | nil) :: String.t() | nil
  def dispatch_target_state(%TrackerIssue{state: issue_state}), do: dispatch_target_state(issue_state)

  def dispatch_target_state(issue_state) do
    normalized_issue_state = normalize_state(issue_state)
    ready_state = normalize_state(Config.settings!().tracker.ready_label)

    if normalized_issue_state == "" or normalized_issue_state != ready_state do
      nil
    else
      active_states()
      |> Enum.find(fn state_name ->
        normalized_state = normalize_state(state_name)
        normalized_state != "" and normalized_state != ready_state
      end)
    end
  end

  @spec initial_dispatch_transition_name() :: String.t() | nil
  def initial_dispatch_transition_name do
    with ready_state when is_binary(ready_state) <- Config.settings!().tracker.ready_label,
         target_state when is_binary(target_state) <- dispatch_target_state(ready_state) do
      DispatchLifecycle.transition_name(ready_state, target_state)
    end
  end

  @spec reconcile_watch_states(
          (String.t(), String.t() -> term()),
          (String.t(), String.t() | nil, String.t() -> term())
        ) :: :ok | {:error, term()}
  def reconcile_watch_states(update_issue_state_fun, mark_pending_transition_fun)
      when is_function(update_issue_state_fun, 2) and is_function(mark_pending_transition_fun, 3) do
    watch_states = watch_state_names()

    if watch_states == [] do
      :ok
    else
      with {:ok, issues} <- fetch_issues_by_states(watch_states) do
        Enum.each(issues, &process_watched_issue(&1, update_issue_state_fun, mark_pending_transition_fun))
        :ok
      end
    end
  end

  @doc false
  @spec dispatch_watched_issue_for_test(
          TrackerIssue.t(),
          [String.t()],
          (String.t(), String.t() -> term()),
          (String.t(), String.t() | nil, String.t() -> term())
        ) :: :ok
  def dispatch_watched_issue_for_test(
        %TrackerIssue{} = issue,
        reasons,
        update_issue_state_fun,
        mark_pending_transition_fun
      )
      when is_list(reasons) and is_function(update_issue_state_fun, 2) and
             is_function(mark_pending_transition_fun, 3) do
    dispatch_watched_issue(issue, reasons, update_issue_state_fun, mark_pending_transition_fun)
  end

  @doc false
  @spec actionable_blocker_for_test([String.t()]) :: boolean()
  def actionable_blocker_for_test(reasons) when is_list(reasons) do
    actionable_blocker?(reasons)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp to_tracker_issues(issues) when is_list(issues) do
    Enum.map(issues, fn
      %Issue{} = issue ->
        Issue.to_tracker_issue(issue, issue.blocked_by || [])

      other ->
        other
    end)
  end

  defp process_watched_issue(issue, update_issue_state_fun, mark_pending_transition_fun) do
    if watched_issue_merge_candidate?(issue) do
      evaluate_watched_issue(issue, update_issue_state_fun, mark_pending_transition_fun)
    else
      Logger.debug("Watch state skip: #{issue_context(issue)} state=#{inspect(issue.state)} not open/non-terminal")
    end
  end

  defp evaluate_watched_issue(issue, update_issue_state_fun, mark_pending_transition_fun) do
    case client_module().check_auto_merge_readiness(issue.id) do
      {:ok, :ready, pr_number} ->
        Logger.info("Auto-merge: #{issue_context(issue)} PR ##{pr_number} is ready; merging")
        handle_ready_watch_issue(issue, pr_number, update_issue_state_fun, mark_pending_transition_fun)

      {:ok, :needs_agent, reasons} ->
        handle_watch_issue_blockers(issue, reasons, update_issue_state_fun, mark_pending_transition_fun)

      {:error, reason} ->
        Logger.debug("Failed to check auto-merge readiness for #{issue_context(issue)}: #{inspect(reason)}")
    end
  end

  defp handle_ready_watch_issue(issue, pr_number, update_issue_state_fun, mark_pending_transition_fun) do
    case client_module().auto_merge_pr(pr_number) do
      :ok ->
        Logger.info("Auto-merge complete: #{issue_context(issue)} PR ##{pr_number}")

      {:error, reason} ->
        Logger.warning("Auto-merge failed for #{issue_context(issue)} PR ##{pr_number}: #{inspect(reason)}; dispatching agent")
        dispatch_watched_issue(issue, ["auto-merge failed: #{inspect(reason)}"], update_issue_state_fun, mark_pending_transition_fun)
    end
  end

  defp handle_watch_issue_blockers(issue, reasons, update_issue_state_fun, mark_pending_transition_fun) do
    if actionable_blocker?(reasons) do
      Logger.info("Watch state dispatch: #{issue_context(issue)} needs agent: #{Enum.join(reasons, ", ")}")
      dispatch_watched_issue(issue, reasons, update_issue_state_fun, mark_pending_transition_fun)
    else
      Logger.debug("Watch state: #{issue_context(issue)} waiting: #{Enum.join(reasons, ", ")}")
    end
  end

  defp dispatch_watched_issue(issue, reasons, update_issue_state_fun, mark_pending_transition_fun) do
    target_state = "status:in-progress"

    transition_name =
      DispatchLifecycle.transition_name(issue.state, target_state) ||
        "review_to_in_progress"

    case update_issue_state_fun.(issue.id, target_state) do
      :ok ->
        case mark_pending_transition_fun.(issue.id, issue.identifier, transition_name) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Unable to persist pending transition for #{issue_context(issue)} transition=#{transition_name}: #{inspect(reason)}")
            :ok
        end

        Logger.info("Watch state transition complete: #{issue_context(issue)} -> status:in-progress (#{Enum.join(reasons, ", ")})")

      {:error, err} ->
        Logger.warning("Failed to transition watched issue #{issue_context(issue)}: #{inspect(err)}")
    end
  end

  defp watch_state_names do
    (Config.settings!().tracker.watch_states || [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_state/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp watched_issue_merge_candidate?(%TrackerIssue{state: state_name}) when is_binary(state_name) do
    normalized_state = normalize_state(state_name)
    normalized_state != "closed" and normalized_state not in terminal_state_names()
  end

  defp watched_issue_merge_candidate?(_issue), do: false

  defp terminal_state_names do
    terminal_states()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp actionable_blocker?(reasons) do
    Enum.any?(reasons, fn reason ->
      reason not in ["no PR approval", "CI checks pending", "no linked PR found", "mergeability pending"]
    end)
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp issue_context(%TrackerIssue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
