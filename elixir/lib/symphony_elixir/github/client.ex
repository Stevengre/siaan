defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST/GraphQL client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Issue

  @rest_endpoint "https://api.github.com"
  @graphql_endpoint "https://api.github.com/graphql"
  @issue_page_size 100
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_candidate_issues(&request/3)
  end

  @doc false
  @spec fetch_candidate_issues_for_test((atom(), String.t(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(request_fun) when is_function(request_fun, 3) do
    fetch_candidate_issues(request_fun)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, &request/3)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issue_states_by_ids(issue_ids, &request/3)
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test(
          [String.t()],
          (atom(), String.t(), keyword() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, request_fun)
      when is_list(issue_ids) and is_function(request_fun, 3) do
    fetch_issue_states_by_ids(issue_ids, request_fun)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, headers} <- github_headers(),
         {:ok, %{status: status}} when status in [200, 201] <-
           request(:post, issue_comments_url(tracker, number), [headers: headers, json: %{"body" => body}]) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, existing_issue} <- fetch_issue_by_number(tracker, number, &request/3),
         %Issue{} = existing_issue <- existing_issue,
         {:ok, headers} <- github_headers(),
         labels <- retarget_status_labels(existing_issue.labels, state_name),
         {:ok, %{status: status}} when status in [200, 201] <-
           request(:patch, issue_url(tracker, number), [headers: headers, json: %{"labels" => labels}]) do
      :ok
    else
      nil -> {:error, :issue_not_found}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    endpoint = github_graphql_endpoint()

    payload = %{
      "query" => query,
      "variables" => variables
    }

    with {:ok, headers} <- github_headers(),
         {:ok, %{status: 200, body: body}} <-
           request_fun.(:post, endpoint, [headers: headers, json: payload]) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub GraphQL request failed status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(raw_issue) when is_map(raw_issue) do
    normalize_issue(raw_issue)
  end

  defp fetch_candidate_issues(request_fun) when is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, issues} <- list_issues_by_labels(tracker, [tracker.ready_label], "open", request_fun) do
      {:ok, issues}
    end
  end

  defp fetch_issues_by_states(state_names, request_fun)
       when is_list(state_names) and is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config() do
      state_names
      |> normalize_state_names()
      |> do_fetch_issues_by_states(tracker, request_fun)
    end
  end

  defp do_fetch_issues_by_states([], _tracker, _request_fun), do: {:ok, []}

  defp do_fetch_issues_by_states(state_names, tracker, request_fun) do
    Enum.reduce_while(state_names, {:ok, {[], MapSet.new()}}, fn state_name, {:ok, {acc, seen}} ->
      case list_issues_by_labels(tracker, [state_name], "all", request_fun) do
        {:ok, issues} ->
          {next_acc, next_seen} = append_new_issues(acc, seen, issues)
          {:cont, {:ok, {next_acc, next_seen}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {issues, _seen}} -> {:ok, issues}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_states_by_ids(issue_ids, request_fun)
       when is_list(issue_ids) and is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config() do
      issue_ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> do_fetch_issue_states_by_ids(tracker, request_fun, [])
    end
  end

  defp do_fetch_issue_states_by_ids([], _tracker, _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp do_fetch_issue_states_by_ids([issue_id | rest], tracker, request_fun, acc) do
    with {:ok, number} <- parse_issue_number(issue_id),
         {:ok, issue} <- fetch_issue_by_number(tracker, number, request_fun) do
      updated_acc = if is_nil(issue), do: acc, else: [issue | acc]
      do_fetch_issue_states_by_ids(rest, tracker, request_fun, updated_acc)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_issues_by_labels(tracker, labels, state, request_fun) do
    with {:ok, headers} <- github_headers() do
      do_list_issues_by_labels(tracker, labels, state, request_fun, headers, 1, [])
    end
  end

  defp do_list_issues_by_labels(tracker, labels, state, request_fun, headers, page, acc) do
    params = [
      state: state,
      labels: Enum.join(labels, ","),
      per_page: @issue_page_size,
      page: page
    ]

    case request_fun.(:get, issues_url(tracker), [headers: headers, params: params]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        normalized =
          body
          |> Enum.reject(&pull_request?/1)
          |> Enum.map(&normalize_issue/1)
          |> Enum.reject(&is_nil/1)

        next_acc = acc ++ normalized

        if length(body) >= @issue_page_size do
          do_list_issues_by_labels(tracker, labels, state, request_fun, headers, page + 1, next_acc)
        else
          {:ok, next_acc}
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_issue_by_number(tracker, number, request_fun) do
    with {:ok, headers} <- github_headers() do
      case request_fun.(:get, issue_url(tracker, number), [headers: headers]) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, normalize_issue(body)}

        {:ok, %{status: 404}} ->
          {:ok, nil}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp append_new_issues(acc, seen, issues) do
    Enum.reduce(issues, {acc, seen}, fn issue, {acc_issues, seen_ids} ->
      if MapSet.member?(seen_ids, issue.id) do
        {acc_issues, seen_ids}
      else
        {acc_issues ++ [issue], MapSet.put(seen_ids, issue.id)}
      end
    end)
  end

  defp normalize_issue(raw_issue) when is_map(raw_issue) do
    number = raw_issue["number"]
    labels = extract_labels(raw_issue)

    %Issue{
      id: issue_id(raw_issue, number),
      number: parse_number(number),
      title: raw_issue["title"],
      body: raw_issue["body"],
      state: issue_state(raw_issue, labels),
      url: raw_issue["html_url"],
      labels: labels,
      assignees: extract_assignees(raw_issue),
      created_at: parse_datetime(raw_issue["created_at"]),
      updated_at: parse_datetime(raw_issue["updated_at"])
    }
  end

  defp normalize_issue(_raw_issue), do: nil

  defp issue_state(raw_issue, labels) do
    Enum.find(labels, &String.starts_with?(&1, "status:")) || raw_issue["state"]
  end

  defp issue_id(_raw_issue, number) when is_integer(number), do: Integer.to_string(number)

  defp issue_id(raw_issue, _number) do
    raw_issue
    |> Map.get("id")
    |> to_string_or_nil()
  end

  defp parse_number(number) when is_integer(number), do: number

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_number(_number), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> normalize_label(name)
      name when is_binary(name) -> normalize_label(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_raw_issue), do: []

  defp extract_assignees(%{"assignees" => assignees}) when is_list(assignees) do
    assignees
    |> Enum.map(fn
      %{"login" => login} when is_binary(login) -> String.trim(login)
      _ -> nil
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp extract_assignees(_raw_issue), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_state_names(state_names) do
    state_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp pull_request?(%{"pull_request" => _}), do: true
  defp pull_request?(_raw_issue), do: false

  defp retarget_status_labels(existing_labels, target_state) do
    normalized_target = normalize_label(target_state)

    existing_labels
    |> Enum.reject(&String.starts_with?(&1, "status:"))
    |> Kernel.++([normalized_target])
    |> Enum.uniq()
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(String.trim(issue_id)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_issue_id), do: {:error, :invalid_github_issue_id}

  defp github_tracker_config do
    tracker = Config.settings!().tracker

    api_key = Map.get(tracker, :api_key)
    {fallback_owner, fallback_name} = parse_repo_slug(Map.get(tracker, :project_slug))
    repo_owner = Map.get(tracker, :repo_owner) || fallback_owner
    repo_name = Map.get(tracker, :repo_name) || fallback_name

    cond do
      not is_binary(api_key) or String.trim(api_key) == "" ->
        {:error, :missing_github_api_token}

      not is_binary(repo_owner) or String.trim(repo_owner) == "" ->
        {:error, :missing_github_repo_owner}

      not is_binary(repo_name) or String.trim(repo_name) == "" ->
        {:error, :missing_github_repo_name}

      true ->
        {:ok,
         %{
           repo_owner: String.trim(repo_owner),
           repo_name: String.trim(repo_name),
           ready_label: normalize_label(Map.get(tracker, :ready_label) || "status:ready")
         }}
    end
  end

  defp github_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"Content-Type", "application/json"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  defp github_graphql_endpoint do
    case Config.settings!().tracker.endpoint do
      "https://api.linear.app/graphql" ->
        @graphql_endpoint

      endpoint when is_binary(endpoint) and endpoint != "" -> endpoint
      _ -> @graphql_endpoint
    end
  end

  defp issues_url(%{repo_owner: owner, repo_name: repo}), do: "#{@rest_endpoint}/repos/#{owner}/#{repo}/issues"

  defp issue_url(tracker, number), do: "#{issues_url(tracker)}/#{number}"
  defp issue_comments_url(tracker, number), do: "#{issue_url(tracker, number)}/comments"

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(value), do: value |> to_string() |> normalize_label()

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp parse_repo_slug(value) when is_binary(value) do
    case value |> String.trim() |> String.split("/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _ -> {nil, nil}
    end
  end

  defp parse_repo_slug(_value), do: {nil, nil}

  defp request(method, url, opts) when is_atom(method) and is_binary(url) and is_list(opts) do
    Req.request(
      Keyword.merge(
        [method: method, url: url, connect_options: [timeout: 30_000]],
        opts
      )
    )
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
