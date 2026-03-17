defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
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

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
