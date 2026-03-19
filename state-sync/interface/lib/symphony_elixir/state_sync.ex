defmodule SymphonyElixir.StateSync do
  @moduledoc """
  Shared state synchronization boundary used by the orchestrator.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.StateSync.GitHub.Adapter, as: GitHubStateSync
  alias SymphonyElixir.StateSync.Local.Adapter, as: LocalStateSync

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback active_states() :: [String.t()]
  @callback terminal_states() :: [String.t()]
  @callback dispatch_target_state(term()) :: String.t() | nil
  @callback initial_dispatch_transition_name() :: String.t() | nil
  @callback reconcile_watch_states(
              (String.t(), String.t() -> term()),
              (String.t(), String.t() | nil, String.t() -> term())
            ) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    implementation().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    implementation().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    implementation().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    implementation().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    implementation().update_issue_state(issue_id, state_name)
  end

  @spec active_states() :: [String.t()]
  def active_states do
    implementation().active_states()
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    implementation().terminal_states()
  end

  @spec dispatch_target_state(term()) :: String.t() | nil
  def dispatch_target_state(issue_or_state) do
    implementation().dispatch_target_state(issue_or_state)
  end

  @spec initial_dispatch_transition_name() :: String.t() | nil
  def initial_dispatch_transition_name do
    implementation().initial_dispatch_transition_name()
  end

  @spec reconcile_watch_states() :: :ok | {:error, term()}
  def reconcile_watch_states do
    implementation().reconcile_watch_states(
      &update_issue_state/2,
      &SymphonyElixir.SessionStats.mark_pending_transition/3
    )
  end

  @spec implementation() :: module()
  def implementation do
    case Config.settings!().state.type do
      "memory" -> SymphonyElixir.StateSync.Memory
      "github" -> GitHubStateSync
      "local" -> LocalStateSync
      _ -> SymphonyElixir.Linear.Adapter
    end
  end

  @deprecated "Use implementation/0 instead; adapter/0 will be removed after 2026-06-30."
  @spec adapter() :: module()
  def adapter, do: implementation()
end
