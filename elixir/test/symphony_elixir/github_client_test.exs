defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.GitHub.Issue

  test "normalize_issue_for_test extracts status labels and assignees" do
    issue =
      Client.normalize_issue_for_test(%{
        "id" => 12_345,
        "number" => 17,
        "title" => "Add adapter",
        "body" => "Implement tracker bridge",
        "html_url" => "https://github.com/acme/repo/issues/17",
        "state" => "open",
        "labels" => [%{"name" => "status:in-progress"}, %{"name" => "Infra"}],
        "assignees" => [%{"login" => "octocat"}],
        "created_at" => "2026-03-01T12:00:00Z",
        "updated_at" => "2026-03-02T13:00:00Z"
      })

    assert %Issue{} = issue
    assert issue.id == "17"
    assert issue.number == 17
    assert issue.state == "status:in-progress"
    assert issue.labels == ["status:in-progress", "infra"]
    assert issue.assignees == ["octocat"]
    assert DateTime.to_iso8601(issue.created_at) == "2026-03-01T12:00:00Z"
    assert DateTime.to_iso8601(issue.updated_at) == "2026-03-02T13:00:00Z"
  end

  test "fetch_candidate_issues_for_test fetches ready-label issues and skips pull requests" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: "acme/repo",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready"
    )

    request_fun = fn method, url, opts ->
      send(self(), {:request, method, url, opts})

      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => 111,
             "number" => 7,
             "title" => "Ready issue",
             "body" => "body",
             "state" => "open",
             "html_url" => "https://github.com/acme/repo/issues/7",
             "labels" => [%{"name" => "status:ready"}],
             "assignees" => []
           },
           %{
             "id" => 222,
             "number" => 8,
             "title" => "Pull request",
             "pull_request" => %{"url" => "https://api.github.com/repos/acme/repo/pulls/8"},
             "labels" => [%{"name" => "status:ready"}],
             "assignees" => []
           }
         ]
       }}
    end

    assert {:ok, [%Issue{id: "7", number: 7, state: "status:ready"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, :get, "https://api.github.com/repos/acme/repo/issues", opts}
    assert Keyword.get(opts, :params)[:labels] == "status:ready"
    assert Keyword.get(opts, :params)[:state] == "open"
  end

  test "fetch_candidate_issues_for_test handles pagination, malformed entries, and status failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready"
    )

    paged_request = fn :get, _url, opts ->
      page = Keyword.fetch!(opts, :params)[:page]

      body =
        if page == 1 do
          Enum.map(1..100, fn number ->
            %{
              "id" => number,
              "number" => number,
              "title" => "Issue #{number}",
              "body" => "Body #{number}",
              "state" => "open",
              "html_url" => "https://github.com/acme/repo/issues/#{number}",
              "labels" => [%{"name" => "status:ready"}],
              "assignees" => []
            }
          end) ++ ["malformed"]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(paged_request)
    assert length(issues) == 100

    status_failure = fn _method, _url, _opts -> {:ok, %{status: 500, body: %{}}} end
    assert {:error, {:github_api_status, 500}} = Client.fetch_candidate_issues_for_test(status_failure)
  end

  test "fetch_issue_states_by_ids_for_test keeps requested id order" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: "acme/repo",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_fun = fn :get, url, _opts ->
      number = url |> String.split("/") |> List.last() |> String.to_integer()

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => number + 1000,
           "number" => number,
           "title" => "Issue #{number}",
           "body" => "Body #{number}",
           "state" => "open",
           "html_url" => "https://github.com/acme/repo/issues/#{number}",
           "labels" => [%{"name" => if(number == 5, do: "status:review", else: "status:in-progress")}],
           "assignees" => []
         }
       }}
    end

    assert {:ok, [%Issue{id: "5"}, %Issue{id: "3"}]} =
             Client.fetch_issue_states_by_ids_for_test(["5", "3"], request_fun)
  end

  test "graphql/3 uses github auth headers and surfaces status failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: "acme/repo",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_fun = fn method, url, opts ->
      send(self(), {:request, method, url, opts})
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "octocat"}}}}}
    end

    assert {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: request_fun)

    assert_receive {:request, :post, "https://api.github.com/graphql", opts}
    headers = Keyword.get(opts, :headers)
    assert {"Authorization", "Bearer gh-token"} in headers

    status_failure = fn _method, _url, _opts -> {:ok, %{status: 503, body: String.duplicate("x", 1_100)}} end

    assert {:error, {:github_api_status, 503}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: status_failure)

    map_body_failure = fn _method, _url, _opts -> {:ok, %{status: 500, body: %{error: "boom"}}} end

    assert {:error, {:github_api_status, 500}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: map_body_failure)
  end

  test "graphql/3 maps legacy linear endpoint to github endpoint when called through this client" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "linear-token"
    )

    request_fun = fn method, url, _opts ->
      send(self(), {:request, method, url})
      {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
    end

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: request_fun)

    assert_receive {:request, :post, "https://api.github.com/graphql"}
  end

  test "public wrappers return fast validation errors without network dependencies" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: nil,
      tracker_repo_name: nil,
      tracker_api_token: nil
    )

    assert {:error, :missing_github_api_token} = Client.fetch_candidate_issues()
    assert {:error, :missing_github_api_token} = Client.fetch_issues_by_states(["status:ready"])
    assert {:error, :missing_github_api_token} = Client.fetch_issue_states_by_ids(["1"])
    assert {:error, :missing_github_api_token} = Client.create_comment("1", "hello")
    assert {:error, :missing_github_api_token} = Client.update_issue_state("1", "status:review")
  end

  test "fetch_candidate_issues_for_test validates required github tracker fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: nil
    )

    assert {:error, :missing_github_api_token} =
             Client.fetch_candidate_issues_for_test(fn _method, _url, _opts ->
               flunk("request function should not be called when config is invalid")
             end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: nil,
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    assert {:error, :missing_github_repo_owner} =
             Client.fetch_candidate_issues_for_test(fn _method, _url, _opts ->
               flunk("request function should not be called when config is invalid")
             end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: nil,
      tracker_api_token: "gh-token"
    )

    assert {:error, :missing_github_repo_name} =
             Client.fetch_candidate_issues_for_test(fn _method, _url, _opts ->
               flunk("request function should not be called when config is invalid")
             end)
  end

  test "fetch_issues_by_states_for_test deduplicates repeated issues and handles empty state filters" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    assert {:ok, []} = Client.fetch_issues_by_states_for_test([], fn _method, _url, _opts -> flunk("no request expected") end)

    request_fun = fn :get, _url, opts ->
      state_label = Keyword.fetch!(opts, :params)[:labels]

      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => 111,
             "number" => 11,
             "title" => "Shared issue #{state_label}",
             "body" => "Body",
             "state" => "open",
             "html_url" => "https://github.com/acme/repo/issues/11",
             "labels" => [%{"name" => "status:in-progress"}],
             "assignees" => []
           }
         ]
       }}
    end

    assert {:ok, [%Issue{id: "11"}]} =
             Client.fetch_issues_by_states_for_test(["status:in-progress", "status:review"], request_fun)
  end

  test "fetch_issues_by_states_for_test surfaces transport failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_failure = fn _method, _url, _opts -> {:error, :timeout} end

    assert {:error, {:github_api_request, :timeout}} =
             Client.fetch_issues_by_states_for_test(["status:review"], request_failure)
  end

  test "fetch_issues_by_states_for_test surfaces non-200 status responses" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    status_failure = fn _method, _url, _opts -> {:ok, %{status: 422, body: %{}}} end
    assert {:error, {:github_api_status, 422}} = Client.fetch_issues_by_states_for_test(["status:review"], status_failure)
  end

  test "fetch_issue_states_by_ids_for_test handles 404 and invalid issue ids" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_fun = fn :get, url, _opts ->
      number = url |> String.split("/") |> List.last() |> String.to_integer()

      case number do
        5 ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => 5005,
               "number" => 5,
               "title" => "Issue 5",
               "body" => "Body",
               "state" => "open",
               "html_url" => "https://github.com/acme/repo/issues/5",
               "labels" => [%{"name" => "status:review"}],
               "assignees" => []
             }
           }}

        9 ->
          {:ok, %{status: 404, body: %{}}}
      end
    end

    assert {:ok, [%Issue{id: "5"}]} =
             Client.fetch_issue_states_by_ids_for_test(["5", "9"], request_fun)

    assert {:error, :invalid_github_issue_id} =
             Client.fetch_issue_states_by_ids_for_test(["bad-id"], request_fun)
  end

  test "create_comment_for_test handles success, status failures, transport failures, and invalid ids" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    success = fn :post, _url, opts ->
      assert Keyword.has_key?(opts, :json)
      {:ok, %{status: 201, body: %{}}}
    end

    assert :ok = Client.create_comment_for_test("7", "hello", success)

    status_failure = fn _method, _url, _opts -> {:ok, %{status: 500, body: %{}}} end
    assert {:error, {:github_api_status, 500}} = Client.create_comment_for_test("7", "hello", status_failure)

    request_failure = fn _method, _url, _opts -> {:error, :closed} end
    assert {:error, :closed} = Client.create_comment_for_test("7", "hello", request_failure)

    malformed = fn _method, _url, _opts -> :unexpected end
    assert {:error, :comment_create_failed} = Client.create_comment_for_test("7", "hello", malformed)

    assert {:error, :invalid_github_issue_id} = Client.create_comment_for_test("bad", "hello", success)
  end

  test "update_issue_state_for_test retargets status labels and handles error branches" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    success = fn method, _url, opts ->
      case method do
        :get ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => 42,
               "number" => 42,
               "title" => "Issue 42",
               "body" => "Body",
               "state" => "open",
               "html_url" => "https://github.com/acme/repo/issues/42",
               "labels" => [%{"name" => "status:ready"}, %{"name" => "infra"}],
               "assignees" => []
             }
           }}

        :patch ->
          labels = get_in(opts, [:json, "labels"])
          assert Enum.sort(labels) == ["infra", "status:review"]
          {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok = Client.update_issue_state_for_test("42", "status:review", success)

    missing_issue = fn method, _url, _opts ->
      if method == :get, do: {:ok, %{status: 404, body: %{}}}, else: flunk("patch should not run")
    end

    assert {:error, :issue_not_found} = Client.update_issue_state_for_test("42", "status:review", missing_issue)

    patch_failure = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: {:ok, %{status: 422, body: %{}}}
    end

    assert {:error, {:github_api_status, 422}} =
             Client.update_issue_state_for_test("42", "status:review", patch_failure)

    request_failure = fn _method, _url, _opts -> {:error, :closed} end

    assert {:error, {:github_api_request, :closed}} =
             Client.update_issue_state_for_test("42", "status:review", request_failure)

    malformed_patch = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: :unexpected
    end

    assert {:error, :issue_update_failed} =
             Client.update_issue_state_for_test("42", "status:review", malformed_patch)

    get_status_failure = fn method, _url, _opts ->
      if method == :get, do: {:ok, %{status: 500, body: %{}}}, else: flunk("patch should not run")
    end

    assert {:error, {:github_api_status, 500}} =
             Client.update_issue_state_for_test("42", "status:review", get_status_failure)

    assert {:error, :invalid_github_issue_id} =
             Client.update_issue_state_for_test("bad", "status:review", success)
  end

  test "graphql/3 surfaces request failures and default request path errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_failure = fn _method, _url, _opts -> {:error, :closed} end

    assert {:error, {:github_api_request, :closed}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: request_failure)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "http://127.0.0.1:1/graphql"
    )

    assert {:error, {:github_api_request, _reason}} =
             Client.graphql("query Viewer { viewer { login } }", %{})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: nil,
      tracker_endpoint: ""
    )

    assert {:error, {:github_api_request, :missing_github_api_token}} =
             Client.graphql("query Viewer { viewer { login } }", %{},
               request_fun: fn _method, _url, _opts ->
                 flunk("request function should not be called when auth is missing")
               end
             )
  end

  test "normalize_issue_for_test falls back to raw state and raw id when needed" do
    issue =
      Client.normalize_issue_for_test(%{
        "id" => "node-1",
        "number" => "17",
        "title" => "Fallback paths",
        "body" => nil,
        "state" => "open",
        "labels" => ["Infra", 123],
        "assignees" => [%{"login" => "octocat"}, %{"id" => "ignored"}]
      })

    assert issue.id == "node-1"
    assert issue.number == 17
    assert issue.state == "open"
    assert issue.labels == ["infra"]
    assert issue.assignees == ["octocat"]

    issue_with_invalid_number =
      Client.normalize_issue_for_test(%{
        "id" => nil,
        "number" => "not-a-number",
        "title" => "Invalid number",
        "state" => "open",
        "created_at" => "not-a-date",
        "updated_at" => "not-a-date"
      })

    assert issue_with_invalid_number.id == nil
    assert issue_with_invalid_number.number == nil
    assert issue_with_invalid_number.created_at == nil
    assert issue_with_invalid_number.updated_at == nil
    assert issue_with_invalid_number.labels == []
    assert issue_with_invalid_number.assignees == []

    issue_with_non_numeric_value =
      Client.normalize_issue_for_test(%{
        "id" => "node-2",
        "number" => %{"bad" => true},
        "labels" => [],
        "assignees" => []
      })

    assert issue_with_non_numeric_value.number == nil
  end
end
