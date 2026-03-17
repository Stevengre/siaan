defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.TrackerIssue

  @spec fetch_candidate_issues() :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %TrackerIssue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %TrackerIssue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec active_states() :: [String.t()]
  def active_states, do: Config.settings!().tracker.active_states || []

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: Config.settings!().tracker.terminal_states || []

  @spec dispatch_target_state(String.t() | nil) :: String.t() | nil
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
      SymphonyElixir.DispatchLifecycle.transition_name(ready_state, target_state)
    end
  end

  @spec reconcile_watch_states(
          (String.t(), String.t() -> term()),
          (String.t(), String.t() | nil, String.t() -> term())
        ) :: :ok | {:error, term()}
  def reconcile_watch_states(_update_issue_state_fun, _mark_pending_transition_fun), do: :ok

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%TrackerIssue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
