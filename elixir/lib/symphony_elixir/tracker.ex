defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Local.Adapter, as: LocalAdapter

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
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec active_states() :: [String.t()]
  def active_states do
    adapter().active_states()
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    adapter().terminal_states()
  end

  @spec dispatch_target_state(term()) :: String.t() | nil
  def dispatch_target_state(issue_or_state) do
    adapter().dispatch_target_state(issue_or_state)
  end

  @spec initial_dispatch_transition_name() :: String.t() | nil
  def initial_dispatch_transition_name do
    adapter().initial_dispatch_transition_name()
  end

  @spec reconcile_watch_states() :: :ok | {:error, term()}
  def reconcile_watch_states do
    adapter().reconcile_watch_states(
      &update_issue_state/2,
      &SymphonyElixir.SessionStats.mark_pending_transition/3
    )
  end

  @spec has_actionable_pr_feedback?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def has_actionable_pr_feedback?(issue_id, allowlist) do
    case adapter() do
      GitHubAdapter -> GitHubClient.has_actionable_pr_feedback?(issue_id, allowlist)
      _ -> {:ok, false}
    end
  end

  @spec has_pr_approval?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def has_pr_approval?(issue_id) do
    case adapter() do
      GitHubAdapter -> GitHubClient.has_pr_approval?(issue_id)
      _ -> {:ok, false}
    end
  end

  @spec check_auto_merge_readiness(String.t()) ::
          {:ok, :ready, pos_integer()} | {:ok, :needs_agent, [String.t()]} | {:error, term()}
  def check_auto_merge_readiness(issue_id) do
    case adapter() do
      GitHubAdapter -> GitHubClient.check_auto_merge_readiness(issue_id)
      _ -> {:ok, :needs_agent, ["unsupported tracker"]}
    end
  end

  @spec auto_merge_pr(pos_integer()) :: :ok | {:error, term()}
  def auto_merge_pr(pr_number) do
    case adapter() do
      GitHubAdapter -> GitHubClient.auto_merge_pr(pr_number)
      _ -> {:error, :unsupported_tracker}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      "github" -> GitHubAdapter
      "local" -> LocalAdapter
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
