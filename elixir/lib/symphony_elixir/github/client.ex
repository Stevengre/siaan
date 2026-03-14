defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST/GraphQL client for issue polling and repository installation tasks.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Issue

  @rest_endpoint "https://api.github.com"
  @graphql_endpoint "https://api.github.com/graphql"
  @issue_page_size 100
  @repo_page_size 100
  @max_error_body_log_bytes 1_000

  @type request_fun :: (atom(), String.t(), keyword() -> {:ok, map()} | {:error, term()})
  @type repo_context :: %{
          repo_owner: String.t(),
          repo_name: String.t(),
          api_key: String.t(),
          rest_endpoint: String.t()
        }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_candidate_issues(&request/3)
  end

  @spec fetch_candidate_issues_for_test(request_fun()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(request_fun) when is_function(request_fun, 3) do
    fetch_candidate_issues(request_fun)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, &request/3)
  end

  @spec fetch_issues_by_states_for_test([String.t()], request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, request_fun)
      when is_list(state_names) and is_function(request_fun, 3) do
    fetch_issues_by_states(state_names, request_fun)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issue_states_by_ids(issue_ids, &request/3)
  end

  @spec fetch_issue_states_by_ids_for_test([String.t()], request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, request_fun)
      when is_list(issue_ids) and is_function(request_fun, 3) do
    fetch_issue_states_by_ids(issue_ids, request_fun)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body, &request/3)
  end

  @spec create_comment_for_test(String.t(), String.t(), request_fun()) :: :ok | {:error, term()}
  def create_comment_for_test(issue_id, body, request_fun)
      when is_binary(issue_id) and is_binary(body) and is_function(request_fun, 3) do
    create_comment(issue_id, body, request_fun)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    update_issue_state(issue_id, state_name, &request/3)
  end

  @spec update_issue_state_for_test(String.t(), String.t(), request_fun()) :: :ok | {:error, term()}
  def update_issue_state_for_test(issue_id, state_name, request_fun)
      when is_binary(issue_id) and is_binary(state_name) and is_function(request_fun, 3) do
    update_issue_state(issue_id, state_name, request_fun)
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &request/3)
    endpoint = github_graphql_endpoint()

    payload = %{"query" => query, "variables" => variables}

    with {:ok, headers} <- github_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(:post, endpoint, headers: headers, json: payload) do
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

  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(raw_issue) when is_map(raw_issue) do
    normalize_issue(raw_issue)
  end

  @spec build_repo_context(String.t(), String.t(), String.t() | nil) :: {:ok, repo_context()} | {:error, term()}
  def build_repo_context(repo_owner, repo_name, api_key \\ nil) do
    with {:ok, normalized_owner} <- ensure_present_string(repo_owner, :missing_github_repo_owner),
         {:ok, normalized_repo} <- ensure_present_string(repo_name, :missing_github_repo_name),
         {:ok, normalized_token} <- ensure_present_string(api_key || System.get_env("GITHUB_TOKEN"), :missing_github_api_token) do
      {:ok,
       %{
         repo_owner: normalized_owner,
         repo_name: normalized_repo,
         api_key: normalized_token,
         rest_endpoint: github_rest_endpoint()
       }}
    end
  end

  @spec list_labels(repo_context()) :: {:ok, [map()]} | {:error, term()}
  def list_labels(repo) when is_map(repo) do
    list_labels(repo, &request/3)
  end

  @spec list_labels_for_test(repo_context(), request_fun()) :: {:ok, [map()]} | {:error, term()}
  def list_labels_for_test(repo, request_fun) when is_map(repo) and is_function(request_fun, 3) do
    list_labels(repo, request_fun)
  end

  @spec create_label(repo_context(), map()) :: :ok | {:error, term()}
  def create_label(repo, attrs) when is_map(repo) and is_map(attrs) do
    create_label(repo, attrs, &request/3)
  end

  @spec create_label_for_test(repo_context(), map(), request_fun()) :: :ok | {:error, term()}
  def create_label_for_test(repo, attrs, request_fun)
      when is_map(repo) and is_map(attrs) and is_function(request_fun, 3) do
    create_label(repo, attrs, request_fun)
  end

  @spec list_collaborators(repo_context()) :: {:ok, [String.t()]} | {:error, term()}
  def list_collaborators(repo) when is_map(repo) do
    list_collaborators(repo, &request/3)
  end

  @spec list_collaborators_for_test(repo_context(), request_fun()) :: {:ok, [String.t()]} | {:error, term()}
  def list_collaborators_for_test(repo, request_fun)
      when is_map(repo) and is_function(request_fun, 3) do
    list_collaborators(repo, request_fun)
  end

  @spec get_branch_protection(repo_context(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_branch_protection(repo, branch) when is_map(repo) and is_binary(branch) do
    get_branch_protection(repo, branch, &request/3)
  end

  @spec get_branch_protection_for_test(repo_context(), String.t(), request_fun()) ::
          {:ok, map() | nil} | {:error, term()}
  def get_branch_protection_for_test(repo, branch, request_fun)
      when is_map(repo) and is_binary(branch) and is_function(request_fun, 3) do
    get_branch_protection(repo, branch, request_fun)
  end

  @spec put_branch_protection(repo_context(), String.t(), map()) :: :ok | {:error, term()}
  def put_branch_protection(repo, branch, payload)
      when is_map(repo) and is_binary(branch) and is_map(payload) do
    put_branch_protection(repo, branch, payload, &request/3)
  end

  @spec put_branch_protection_for_test(repo_context(), String.t(), map(), request_fun()) ::
          :ok | {:error, term()}
  def put_branch_protection_for_test(repo, branch, payload, request_fun)
      when is_map(repo) and is_binary(branch) and is_map(payload) and is_function(request_fun, 3) do
    put_branch_protection(repo, branch, payload, request_fun)
  end

  @spec get_default_branch(repo_context()) :: {:ok, String.t()} | {:error, term()}
  def get_default_branch(repo) when is_map(repo) do
    get_default_branch(repo, &request/3)
  end

  @spec get_default_branch_for_test(repo_context(), request_fun()) :: {:ok, String.t()} | {:error, term()}
  def get_default_branch_for_test(repo, request_fun)
      when is_map(repo) and is_function(request_fun, 3) do
    get_default_branch(repo, request_fun)
  end

  defp fetch_candidate_issues(request_fun) when is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config() do
      tracker.active_states
      |> normalize_state_names()
      |> do_fetch_candidate_issues_by_states(tracker, request_fun)
    end
  end

  defp do_fetch_candidate_issues_by_states([], tracker, request_fun) do
    list_issues_by_labels(tracker, [tracker.ready_label], "open", request_fun)
  end

  defp do_fetch_candidate_issues_by_states(state_names, tracker, request_fun) do
    Enum.reduce_while(state_names, {:ok, {[], MapSet.new()}}, fn state_name, {:ok, {acc, seen}} ->
      case list_candidate_issues_for_state_name(tracker, state_name, request_fun) do
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

  defp list_candidate_issues_for_state_name(tracker, state_name, request_fun) do
    case state_name |> to_string() |> String.trim() |> String.downcase() do
      "closed" -> {:ok, []}
      "open" -> list_issues_by_labels(tracker, [], "open", request_fun)
      _ -> list_issues_by_labels(tracker, [state_name], "open", request_fun)
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
      case list_issues_for_state_name(tracker, state_name, request_fun) do
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

  defp list_issues_for_state_name(tracker, state_name, request_fun) do
    case state_name |> to_string() |> String.trim() |> String.downcase() do
      "open" -> list_issues_by_labels(tracker, [], "open", request_fun)
      "closed" -> list_issues_by_labels(tracker, [], "closed", request_fun)
      _ -> list_issues_by_labels(tracker, [state_name], "all", request_fun)
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

  defp create_comment(issue_id, body, request_fun) when is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, headers} <- github_headers(),
         {:ok, %{status: status}} when status in [200, 201] <-
           request_fun.(:post, issue_comments_url(tracker, number), headers: headers, json: %{"body" => body}) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp update_issue_state(issue_id, state_name, request_fun) when is_function(request_fun, 3) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, existing_issue} <- fetch_issue_by_number(tracker, number, request_fun),
         %Issue{} = existing_issue <- existing_issue,
         {:ok, headers} <- github_headers(),
         labels <- retarget_status_labels(existing_issue.labels, state_name),
         {:ok, %{status: status}} when status in [200, 201] <-
           request_fun.(:patch, issue_url(tracker, number), headers: headers, json: %{"labels" => labels}) do
      :ok
    else
      nil -> {:error, :issue_not_found}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp list_issues_by_labels(tracker, labels, state, request_fun) do
    with {:ok, headers} <- github_headers() do
      do_list_issues_by_labels(tracker, labels, state, request_fun, headers, 1, [])
    end
  end

  defp do_list_issues_by_labels(tracker, labels, state, request_fun, headers, page, acc) do
    params =
      [state: state, per_page: @issue_page_size, page: page]
      |> maybe_put_labels_param(labels)

    case request_fun.(:get, issues_url(tracker), headers: headers, params: params) do
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
      case request_fun.(:get, issue_url(tracker, number), headers: headers) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, normalize_issue(body)}
        {:ok, %{status: 404}} -> {:ok, nil}
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp list_labels(repo, request_fun) do
    with {:ok, headers} <- repo_headers(repo),
         {:ok, %{status: 200, body: body}} when is_list(body) <-
           request_fun.(:get, labels_url(repo), headers: headers, params: [per_page: @repo_page_size]) do
      {:ok, body}
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp create_label(repo, attrs, request_fun) do
    with {:ok, headers} <- repo_headers(repo),
         {:ok, %{status: status}} when status in [200, 201] <-
           request_fun.(:post, labels_url(repo), headers: headers, json: attrs) do
      :ok
    else
      {:ok, %{status: 422}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp list_collaborators(repo, request_fun) do
    with {:ok, headers} <- repo_headers(repo) do
      do_list_collaborators(repo, request_fun, headers, 1, [])
    end
  end

  defp do_list_collaborators(repo, request_fun, headers, page, acc) do
    params = [per_page: @repo_page_size, page: page]

    case request_fun.(:get, collaborators_url(repo), headers: headers, params: params) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        next_acc = acc ++ normalize_collaborators(body)

        if length(body) >= @repo_page_size do
          do_list_collaborators(repo, request_fun, headers, page + 1, next_acc)
        else
          {:ok, next_acc |> Enum.uniq() |> Enum.sort()}
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp normalize_collaborators(body) do
    body
    |> Enum.map(&Map.get(&1, "login"))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp get_branch_protection(repo, branch, request_fun) do
    with {:ok, headers} <- repo_headers(repo) do
      protection_headers = [{"Accept", "application/vnd.github+json"} | headers]

      case request_fun.(:get, branch_protection_url(repo, branch), headers: protection_headers) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: 404}} -> {:ok, nil}
        {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp put_branch_protection(repo, branch, payload, request_fun) do
    with {:ok, headers} <- repo_headers(repo),
         protection_headers <- [{"Accept", "application/vnd.github+json"} | headers],
         {:ok, %{status: status}} when status in [200, 201] <-
           request_fun.(:put, branch_protection_url(repo, branch), headers: protection_headers, json: payload) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp get_default_branch(repo, request_fun) do
    with {:ok, headers} <- repo_headers(repo),
         {:ok, %{status: 200, body: body}} when is_map(body) <-
           request_fun.(:get, repo_url(repo), headers: headers),
         {:ok, branch} <- extract_default_branch(body) do
      {:ok, branch}
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
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
    case raw_issue["state"] do
      state when is_binary(state) and state != "" ->
        if String.downcase(state) == "closed" do
          "closed"
        else
          Enum.find(labels, &String.starts_with?(&1, "status:")) || state
        end

      _ ->
        Enum.find(labels, &String.starts_with?(&1, "status:")) || raw_issue["state"]
    end
  end

  defp issue_id(_raw_issue, number) when is_integer(number), do: Integer.to_string(number)
  defp issue_id(raw_issue, _number), do: raw_issue |> Map.get("id") |> to_string_or_nil()

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

  defp github_tracker_config do
    tracker = Config.settings!().tracker

    with {:ok, _api_key} <- ensure_present_string(tracker.api_key, :missing_github_api_token),
         {:ok, normalized_owner} <- ensure_present_string(tracker.repo_owner, :missing_github_repo_owner),
         {:ok, normalized_repo} <- ensure_present_string(tracker.repo_name, :missing_github_repo_name) do
      {:ok,
       %{
         repo_owner: normalized_owner,
         repo_name: normalized_repo,
         ready_label: normalize_label(tracker.ready_label || "status:ready"),
         active_states: normalize_state_names(tracker.active_states || []),
         api_key: tracker.api_key,
         rest_endpoint: github_rest_endpoint()
       }}
    end
  end

  defp github_headers do
    tracker = Config.settings!().tracker
    repo_headers(%{api_key: tracker.api_key})
  end

  defp repo_headers(repo) do
    with {:ok, token} <- ensure_present_string(repo.api_key, :missing_github_api_token) do
      {:ok,
       [
         {"Authorization", "Bearer #{token}"},
         {"Accept", "application/vnd.github+json"},
         {"X-GitHub-Api-Version", "2022-11-28"},
         {"Content-Type", "application/json"}
       ]}
    end
  end

  defp github_graphql_endpoint do
    tracker = Config.settings!().tracker

    if tracker.endpoint == "https://api.linear.app/graphql",
      do: @graphql_endpoint,
      else: tracker.endpoint
  end

  defp github_rest_endpoint do
    tracker = Config.settings!().tracker

    endpoint =
      if tracker.endpoint == "https://api.linear.app/graphql",
        do: @graphql_endpoint,
        else: tracker.endpoint

    rest_endpoint_from_graphql(endpoint)
  end

  defp rest_endpoint_from_graphql(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    case {uri.scheme, uri.host} do
      {scheme, host} when is_binary(scheme) and is_binary(host) ->
        normalized_path = String.trim_trailing(uri.path || "", "/")

        path =
          cond do
            normalized_path == "" ->
              ""

            String.ends_with?(normalized_path, "/api/graphql") ->
              String.replace_suffix(normalized_path, "/api/graphql", "/api/v3")

            String.ends_with?(normalized_path, "/graphql") ->
              String.replace_suffix(normalized_path, "/graphql", "")

            true ->
              normalized_path
          end

        uri
        |> Map.put(:path, path)
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        @rest_endpoint
    end
  end

  defp repo_url(%{repo_owner: owner, repo_name: repo} = context),
    do: "#{rest_endpoint(context)}/repos/#{owner}/#{repo}"

  defp issues_url(context), do: "#{repo_url(context)}/issues"
  defp issue_url(tracker, number), do: "#{issues_url(tracker)}/#{number}"
  defp issue_comments_url(tracker, number), do: "#{issue_url(tracker, number)}/comments"
  defp labels_url(context), do: "#{repo_url(context)}/labels"
  defp collaborators_url(context), do: "#{repo_url(context)}/collaborators"

  defp branch_protection_url(%{repo_owner: owner, repo_name: repo} = context, branch) do
    encoded_branch = URI.encode(branch, &URI.char_unreserved?/1)
    "#{rest_endpoint(context)}/repos/#{owner}/#{repo}/branches/#{encoded_branch}/protection"
  end

  defp rest_endpoint(%{rest_endpoint: endpoint}) when is_binary(endpoint) and endpoint != "", do: endpoint
  defp rest_endpoint(_context), do: @rest_endpoint

  defp maybe_put_labels_param(params, labels) when is_list(labels) do
    cleaned_labels =
      labels
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case cleaned_labels do
      [] -> params
      _ -> Keyword.put(params, :labels, Enum.join(cleaned_labels, ","))
    end
  end

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp ensure_present_string(value, error) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, error}, else: {:ok, trimmed}
  end

  defp ensure_present_string(_value, error), do: {:error, error}

  defp extract_default_branch(%{"default_branch" => branch}) when is_binary(branch) do
    ensure_present_string(branch, :missing_default_branch)
  end

  defp extract_default_branch(_body), do: {:error, :missing_default_branch}

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
