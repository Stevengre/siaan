defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{Client, Issue}

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

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp to_tracker_issues(issues) when is_list(issues) do
    blocker_lookup = resolve_blocker_lookup(issues)

    Enum.map(issues, fn
      %Issue{} = issue ->
        blocked_by = build_blocked_by(issue, blocker_lookup)
        Issue.to_tracker_issue(issue, blocked_by)

      other ->
        other
    end)
  end

  defp resolve_blocker_lookup(issues) do
    known_by_number =
      issues
      |> Enum.filter(&match?(%Issue{number: n} when is_integer(n), &1))
      |> Map.new(fn %Issue{number: n} = i -> {n, i} end)

    unknown_numbers =
      issues
      |> Enum.flat_map(fn
        %Issue{} = issue -> Issue.extract_blocker_numbers(issue)
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(known_by_number, &1))

    fetched =
      case unknown_numbers do
        [] ->
          %{}

        nums ->
          ids = Enum.map(nums, &Integer.to_string/1)

          case client_module().fetch_issue_states_by_ids(ids) do
            {:ok, fetched_issues} ->
              fetched_issues
              |> Enum.filter(&match?(%Issue{number: n} when is_integer(n), &1))
              |> Map.new(fn %Issue{number: n} = i -> {n, i} end)

            {:error, _} ->
              %{}
          end
      end

    Map.merge(known_by_number, fetched)
  end

  defp build_blocked_by(%Issue{} = issue, lookup) do
    issue
    |> Issue.extract_blocker_numbers()
    |> Enum.map(fn num ->
      case Map.get(lookup, num) do
        %Issue{} = blocker ->
          %{
            id: Integer.to_string(num),
            identifier: "GH-#{num}",
            state: Issue.status_label(blocker) || blocker.state || "open"
          }

        nil ->
          %{id: Integer.to_string(num), identifier: "GH-#{num}", state: "unknown"}
      end
    end)
  end
end
