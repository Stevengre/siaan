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
  @valid_issue_state_transitions %{
    "status:triage" => ["status:ready"],
    "status:ready" => ["status:in-progress"],
    "status:in-progress" => ["status:review"],
    "status:review" => ["status:in-progress"]
  }

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

  @spec has_actionable_pr_feedback?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def has_actionable_pr_feedback?(issue_id, allowlist)
      when is_binary(issue_id) and is_list(allowlist) do
    has_actionable_pr_feedback?(issue_id, allowlist, &request/3)
  end

  @spec has_actionable_pr_feedback_for_test(String.t(), [String.t()], request_fun()) ::
          {:ok, boolean()} | {:error, term()}
  def has_actionable_pr_feedback_for_test(issue_id, allowlist, request_fun)
      when is_binary(issue_id) and is_list(allowlist) and is_function(request_fun, 3) do
    has_actionable_pr_feedback?(issue_id, allowlist, request_fun)
  end

  @spec has_pr_approval?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def has_pr_approval?(issue_id) when is_binary(issue_id) do
    has_pr_approval?(issue_id, &request/3)
  end

  @spec has_pr_approval_for_test(String.t(), request_fun()) :: {:ok, boolean()} | {:error, term()}
  def has_pr_approval_for_test(issue_id, request_fun)
      when is_binary(issue_id) and is_function(request_fun, 3) do
    has_pr_approval?(issue_id, request_fun)
  end

  @reply_prefix "[siaan]"
  @pulls_per_page 100

  @type auto_merge_result :: {:ok, :ready, pos_integer()} | {:ok, :needs_agent, [String.t()]} | {:error, term()}

  @spec check_auto_merge_readiness(String.t()) :: auto_merge_result()
  def check_auto_merge_readiness(issue_id) when is_binary(issue_id) do
    check_auto_merge_readiness(issue_id, &request/3)
  end

  @spec check_auto_merge_readiness_for_test(String.t(), request_fun()) :: auto_merge_result()
  def check_auto_merge_readiness_for_test(issue_id, request_fun)
      when is_binary(issue_id) and is_function(request_fun, 3) do
    check_auto_merge_readiness(issue_id, request_fun)
  end

  @spec auto_merge_pr(pos_integer()) :: :ok | {:error, term()}
  def auto_merge_pr(pr_number) when is_integer(pr_number) do
    auto_merge_pr(pr_number, &request/3)
  end

  @spec auto_merge_pr_for_test(pos_integer(), request_fun()) :: :ok | {:error, term()}
  def auto_merge_pr_for_test(pr_number, request_fun)
      when is_integer(pr_number) and is_function(request_fun, 3) do
    auto_merge_pr(pr_number, request_fun)
  end

  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(raw_issue) when is_map(raw_issue) do
    normalize_issue(raw_issue)
  end

  @spec build_repo_context(String.t(), String.t(), String.t() | nil) ::
          {:ok, repo_context()} | {:error, term()}
  def build_repo_context(repo_owner, repo_name, api_key \\ nil) do
    build_repo_context(repo_owner, repo_name, api_key, [])
  end

  @spec build_repo_context(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, repo_context()} | {:error, term()}
  def build_repo_context(repo_owner, repo_name, api_key, opts) when is_list(opts) do
    with {:ok, normalized_owner} <- ensure_present_string(repo_owner, :missing_github_repo_owner),
         {:ok, normalized_repo} <- ensure_present_string(repo_name, :missing_github_repo_name),
         {:ok, normalized_token} <- ensure_present_string(api_key || System.get_env("GITHUB_TOKEN"), :missing_github_api_token) do
      {:ok,
       %{
         repo_owner: normalized_owner,
         repo_name: normalized_repo,
         api_key: normalized_token,
         rest_endpoint: repo_context_rest_endpoint(opts)
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

  defp do_fetch_candidate_issues_by_states([], _tracker, _request_fun), do: {:ok, []}

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
         {:ok, normalized_state_name} <- validate_issue_state_transition(existing_issue.state, state_name),
         {:ok, headers} <- github_headers(),
         labels <- retarget_status_labels(existing_issue.labels, normalized_state_name),
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
      {:ok, %{status: 422, body: body}} -> {:error, {:github_api_status, 422, body}}
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

  defp validate_issue_state_transition(current_state, target_state) do
    normalized_current = normalize_issue_transition_state(current_state)
    normalized_target = normalize_issue_transition_state(target_state)

    cond do
      normalized_current == normalized_target and valid_issue_state_target?(normalized_target) ->
        {:ok, normalized_target}

      normalized_current == "open" and normalized_target == "status:triage" ->
        {:ok, normalized_target}

      normalized_target in Map.get(@valid_issue_state_transitions, normalized_current, []) ->
        {:ok, normalized_target}

      true ->
        {:error, {:invalid_issue_state_transition, normalized_current, normalized_target}}
    end
  end

  defp valid_issue_state_target?(state_name) do
    Map.has_key?(@valid_issue_state_transitions, state_name)
  end

  defp normalize_issue_transition_state(state_name) when is_binary(state_name) do
    trimmed = String.trim(state_name)

    if String.starts_with?(trimmed, "status:") do
      normalize_label(trimmed)
    else
      String.downcase(trimmed)
    end
  end

  defp normalize_issue_transition_state(state_name) do
    case to_string_or_nil(state_name) do
      nil -> nil
      normalized -> normalize_issue_transition_state(normalized)
    end
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(String.trim(issue_id)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp github_tracker_config do
    settings = Config.settings!()
    tracker = settings.tracker

    with {:ok, _api_key} <- ensure_present_string(tracker.api_key, :missing_github_api_token),
         {:ok, normalized_owner} <- ensure_present_string(tracker.repo_owner, :missing_github_repo_owner),
         {:ok, normalized_repo} <- ensure_present_string(tracker.repo_name, :missing_github_repo_name) do
      {:ok,
       %{
         repo_owner: normalized_owner,
         repo_name: normalized_repo,
         ready_label: normalize_label(tracker.ready_label || "status:ready"),
         active_states: normalize_state_names(tracker.active_states || []),
         allowlist: normalize_state_names(settings.allowlist),
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
    case Config.settings() do
      {:ok, settings} ->
        endpoint =
          if settings.tracker.endpoint == "https://api.linear.app/graphql",
            do: @graphql_endpoint,
            else: settings.tracker.endpoint

        rest_endpoint_from_graphql(endpoint)

      {:error, _reason} ->
        @rest_endpoint
    end
  end

  defp repo_context_rest_endpoint(opts) do
    case Keyword.get(opts, :rest_endpoint) do
      endpoint when is_binary(endpoint) ->
        case String.trim(endpoint) do
          "" -> github_rest_endpoint()
          trimmed -> trimmed
        end

      _ ->
        github_rest_endpoint()
    end
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

  defp check_auto_merge_readiness(issue_id, request_fun) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, headers} <- github_headers(),
         {:ok, pr_number} <- find_linked_pr_number(tracker, number, headers, request_fun) do
      do_check_auto_merge_readiness(tracker, pr_number, headers, request_fun)
    else
      {:error, :no_pr} -> {:ok, :needs_agent, ["no linked PR found"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_check_auto_merge_readiness(tracker, pr_number, headers, request_fun) do
    with {:ok, pr_data} <- fetch_pr_data(tracker, pr_number, headers, request_fun) do
      blockers =
        merge_conflict_blockers(pr_data)
        |> Kernel.++(ci_blockers(tracker, pr_data, headers, request_fun))
        |> Kernel.++(approval_blockers(tracker, pr_number, headers, request_fun))
        |> Kernel.++(comment_blockers(tracker, pr_number, headers, request_fun))

      readiness_result(blockers, pr_number)
    end
  end

  defp merge_conflict_blockers(%{mergeable: "CONFLICTING"}), do: ["merge conflicts"]
  defp merge_conflict_blockers(_pr_data), do: []

  defp ci_blockers(tracker, pr_data, headers, request_fun) do
    case check_ci_status(tracker, pr_data.head_sha, headers, request_fun) do
      {:ok, :green} -> []
      {:ok, :pending} -> ["CI checks pending"]
      {:ok, :failed} -> ["CI checks failed"]
      {:error, _} -> ["failed to check CI"]
    end
  end

  defp approval_blockers(tracker, pr_number, headers, request_fun) do
    case check_pr_approved(tracker, pr_number, headers, request_fun) do
      {:ok, true} -> []
      {:ok, false} -> ["no PR approval"]
      {:error, _} -> ["failed to check approval"]
    end
  end

  defp comment_blockers(tracker, pr_number, headers, request_fun) do
    case check_unanswered_comments(tracker, pr_number, headers, request_fun) do
      {:ok, []} -> []
      {:ok, reasons} -> Enum.reverse(reasons)
      {:error, _} -> ["failed to check comments"]
    end
  end

  defp readiness_result([], pr_number), do: {:ok, :ready, pr_number}
  defp readiness_result(blockers, _pr_number), do: {:ok, :needs_agent, blockers}

  defp fetch_pr_data(tracker, pr_number, headers, request_fun) do
    url = "#{repo_url(tracker)}/pulls/#{pr_number}"

    case request_fun.(:get, url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok,
         %{
           mergeable: body["mergeable_state"],
           head_sha: body["head"] |> get_in_safe(["sha"]),
           title: body["title"],
           body: body["body"]
         }}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp get_in_safe(nil, _keys), do: nil
  defp get_in_safe(data, []), do: data
  defp get_in_safe(data, [key | rest]) when is_map(data), do: get_in_safe(Map.get(data, key), rest)
  defp get_in_safe(_data, _keys), do: nil

  defp check_ci_status(tracker, head_sha, headers, request_fun) when is_binary(head_sha) do
    url = "#{repo_url(tracker)}/commits/#{head_sha}/check-runs"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: %{"check_runs" => check_runs}}} when is_list(check_runs) ->
        cond do
          check_runs == [] -> {:ok, :green}
          Enum.any?(check_runs, &ci_check_failed?/1) -> {:ok, :failed}
          Enum.any?(check_runs, &ci_check_pending?/1) -> {:ok, :pending}
          true -> {:ok, :green}
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp check_ci_status(_tracker, _head_sha, _headers, _request_fun), do: {:ok, :green}

  defp ci_check_failed?(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion not in ["success", "skipped", "neutral"],
       do: true

  defp ci_check_failed?(_check), do: false

  defp ci_check_pending?(%{"status" => status}) when status != "completed", do: true
  defp ci_check_pending?(_check), do: false

  defp check_unanswered_comments(tracker, pr_number, headers, request_fun) do
    allowlist_set = tracker.allowlist |> MapSet.new(&String.downcase/1)

    with {:ok, issue_comments} <- fetch_pr_issue_comments(tracker, pr_number, headers, request_fun),
         {:ok, review_comments} <- fetch_pr_review_comments(tracker, pr_number, headers, request_fun) do
      blockers = []

      blockers =
        if has_unanswered_issue_comments?(issue_comments, allowlist_set),
          do: ["unanswered PR comments" | blockers],
          else: blockers

      blockers =
        if has_unanswered_review_comments?(review_comments, allowlist_set),
          do: ["unanswered review comments" | blockers],
          else: blockers

      {:ok, blockers}
    end
  end

  defp fetch_pr_issue_comments(tracker, pr_number, headers, request_fun) do
    url = "#{repo_url(tracker)}/issues/#{pr_number}/comments"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_pr_review_comments(tracker, pr_number, headers, request_fun) do
    url = "#{repo_url(tracker)}/pulls/#{pr_number}/comments"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp has_unanswered_issue_comments?(comments, allowlist_set) do
    # Find the latest [siaan] reply timestamp
    latest_reply_at = latest_siaan_reply_time(comments)

    Enum.any?(comments, fn comment ->
      login = get_in(comment, ["user", "login"]) || ""
      body = (comment["body"] || "") |> String.trim()

      # Only actionable allowlist comments block auto-merge.
      MapSet.member?(allowlist_set, String.downcase(login)) and
        not String.starts_with?(body, @reply_prefix) and
        not codex_review_request?(body) and
        not String.starts_with?(body, "## Codex Review") and
        comment_after_latest_reply?(comment, latest_reply_at)
    end)
  end

  defp has_unanswered_review_comments?(comments, allowlist_set) do
    # Group by thread (in_reply_to_id), check if each thread has a [siaan] reply
    threads =
      comments
      |> Enum.group_by(fn comment ->
        comment["in_reply_to_id"] || comment["id"]
      end)

    Enum.any?(threads, fn {_thread_id, thread_comments} ->
      has_human_comment =
        Enum.any?(thread_comments, fn c ->
          login = get_in(c, ["user", "login"]) || ""
          body = (c["body"] || "") |> String.trim()

          MapSet.member?(allowlist_set, String.downcase(login)) and
            not String.starts_with?(body, @reply_prefix) and
            not codex_review_request?(body) and
            not String.starts_with?(body, "## Codex Review")
        end)

      has_siaan_reply =
        Enum.any?(thread_comments, fn c ->
          body = (c["body"] || "") |> String.trim()
          String.starts_with?(body, @reply_prefix)
        end)

      has_human_comment and not has_siaan_reply
    end)
  end

  defp latest_siaan_reply_time(comments) do
    comments
    |> Enum.filter(fn c ->
      body = (c["body"] || "") |> String.trim()
      String.starts_with?(body, @reply_prefix)
    end)
    |> Enum.map(fn c -> c["created_at"] || c["updated_at"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp comment_after_latest_reply?(_comment, nil), do: true

  defp comment_after_latest_reply?(comment, latest_reply_at) do
    comment_at = comment["created_at"] || comment["updated_at"]

    case comment_at do
      nil -> true
      _ -> comment_at > latest_reply_at
    end
  end

  defp codex_review_request?(body) when is_binary(body) do
    Regex.match?(~r/@codex\b.*\breview\b/i, body)
  end

  defp auto_merge_pr(pr_number, request_fun) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, headers} <- github_headers() do
      :ok = update_pr_branch(tracker, pr_number, headers, request_fun)
      merge_pr(tracker, pr_number, headers, request_fun)
    end
  end

  defp update_pr_branch(tracker, pr_number, headers, request_fun) do
    update_url = "#{repo_url(tracker)}/pulls/#{pr_number}/update-branch"

    case request_fun.(:put, update_url, headers: headers, json: %{}) do
      {:ok, %{status: status}} when status in [200, 202] -> :ok
      # Already up to date
      {:ok, %{status: 422}} -> :ok
      # Best effort; merge will fail if branch is behind
      _ -> :ok
    end
  end

  defp merge_pr(tracker, pr_number, headers, request_fun) do
    merge_url = "#{repo_url(tracker)}/pulls/#{pr_number}/merge"
    merge_payload = %{"merge_method" => "squash"}

    case request_fun.(:put, merge_url, headers: headers, json: merge_payload) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        message = if is_map(body), do: body["message"], else: inspect(body)
        {:error, {:merge_failed, status, message}}

      {:error, reason} ->
        {:error, {:merge_request_failed, reason}}
    end
  end

  defp has_pr_approval?(issue_id, request_fun) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, headers} <- github_headers(),
         {:ok, pr_number} <- find_linked_pr_number(tracker, number, headers, request_fun) do
      check_pr_approved(tracker, pr_number, headers, request_fun)
    else
      {:error, :no_pr} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_pr_approved(tracker, pr_number, headers, request_fun) do
    url = "#{repo_url(tracker)}/pulls/#{pr_number}/reviews"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        # Dedupe by user, keep latest review per user
        latest_by_user =
          body
          |> Enum.filter(&is_map/1)
          |> Enum.group_by(fn review -> get_in(review, ["user", "login"]) end)
          |> Enum.map(fn {_login, reviews} -> List.last(reviews) end)

        has_approval =
          Enum.any?(latest_by_user, fn review ->
            review["state"] == "APPROVED"
          end)

        {:ok, has_approval}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp has_actionable_pr_feedback?(issue_id, allowlist, request_fun) do
    with {:ok, tracker} <- github_tracker_config(),
         {:ok, number} <- parse_issue_number(issue_id),
         {:ok, headers} <- github_headers(),
         {:ok, pr_number} <- find_linked_pr_number(tracker, number, headers, request_fun) do
      check_pr_for_actionable_comments(tracker, pr_number, allowlist, headers, request_fun)
    else
      {:error, :no_pr} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_linked_pr_number(tracker, issue_number, headers, request_fun) do
    url = "#{repo_url(tracker)}/pulls"
    find_linked_pr_number_page(url, issue_number, headers, request_fun, 1)
  end

  defp find_linked_pr_number_page(url, issue_number, headers, request_fun, page) do
    params = [state: "open", per_page: @pulls_per_page, page: page]

    case request_fun.(:get, url, headers: headers, params: params) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        resolve_linked_pr_page(body, issue_number, url, headers, request_fun, page)

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp resolve_linked_pr_page(body, issue_number, url, headers, request_fun, page) do
    case find_issue_closing_pr_number(body, issue_number) do
      {:ok, pr_number} -> {:ok, pr_number}
      :not_found -> continue_linked_pr_page_search(body, issue_number, url, headers, request_fun, page)
    end
  end

  defp continue_linked_pr_page_search(body, _issue_number, _url, _headers, _request_fun, _page)
       when length(body) < @pulls_per_page,
       do: {:error, :no_pr}

  defp continue_linked_pr_page_search(_body, issue_number, url, headers, request_fun, page) do
    find_linked_pr_number_page(url, issue_number, headers, request_fun, page + 1)
  end

  defp find_issue_closing_pr_number(prs, issue_number) when is_list(prs) do
    issue_ref = "closes ##{issue_number}"
    issue_ref_alt = "Closes ##{issue_number}"

    case Enum.find(prs, fn pr ->
           pr_body = pr["body"] || ""
           String.contains?(pr_body, issue_ref) or String.contains?(pr_body, issue_ref_alt)
         end) do
      %{"number" => pr_number} -> {:ok, pr_number}
      _ -> :not_found
    end
  end

  defp check_pr_for_actionable_comments(tracker, pr_number, allowlist, headers, request_fun) do
    normalized_allowlist = MapSet.new(allowlist, &String.downcase/1)

    with {:ok, has_review_comments} <-
           check_pr_review_comments(tracker, pr_number, normalized_allowlist, headers, request_fun),
         {:ok, has_issue_comments} <-
           check_pr_issue_comments(tracker, pr_number, normalized_allowlist, headers, request_fun) do
      {:ok, has_review_comments or has_issue_comments}
    end
  end

  defp check_pr_review_comments(tracker, pr_number, allowlist_set, headers, request_fun) do
    url = "#{repo_url(tracker)}/pulls/#{pr_number}/comments"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        has_actionable =
          Enum.any?(body, fn comment ->
            login = get_in(comment, ["user", "login"]) || ""
            MapSet.member?(allowlist_set, String.downcase(login))
          end)

        {:ok, has_actionable}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp check_pr_issue_comments(tracker, pr_number, allowlist_set, headers, request_fun) do
    url = "#{repo_url(tracker)}/issues/#{pr_number}/comments"

    case request_fun.(:get, url, headers: headers, params: [per_page: 100]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        has_actionable =
          Enum.any?(body, fn comment ->
            login = get_in(comment, ["user", "login"]) || ""
            MapSet.member?(allowlist_set, String.downcase(login))
          end)

        {:ok, has_actionable}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

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
