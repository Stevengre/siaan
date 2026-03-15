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

    closed_issue =
      Client.normalize_issue_for_test(%{
        "id" => 22_222,
        "number" => 22,
        "title" => "Closed issue",
        "body" => "Done",
        "html_url" => "https://github.com/acme/repo/issues/22",
        "state" => "closed",
        "labels" => [%{"name" => "status:in-progress"}],
        "assignees" => []
      })

    assert %Issue{} = closed_issue
    assert closed_issue.state == "closed"
  end

  test "fetch_candidate_issues_for_test fetches all active-state labels and skips pull requests" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: "acme/repo",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready", "status:in-progress"]
    )

    request_fun = fn method, url, opts ->
      send(self(), {:request, method, url, opts})

      labels = Keyword.get(opts, :params)[:labels]

      {:ok,
       %{
         status: 200,
         body:
           case labels do
             "status:ready" ->
               [
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

             "status:in-progress" ->
               [
                 %{
                   "id" => 333,
                   "number" => 9,
                   "title" => "In progress issue",
                   "body" => "body",
                   "state" => "open",
                   "html_url" => "https://github.com/acme/repo/issues/9",
                   "labels" => [%{"name" => "status:in-progress"}],
                   "assignees" => []
                 }
               ]
           end
       }}
    end

    assert {:ok, [%Issue{id: "7", number: 7, state: "status:ready"}, %Issue{id: "9", number: 9, state: "status:in-progress"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, :get, "https://api.github.com/repos/acme/repo/issues", ready_opts}
    assert Keyword.get(ready_opts, :params)[:labels] == "status:ready"
    assert Keyword.get(ready_opts, :params)[:state] == "open"

    assert_receive {:request, :get, "https://api.github.com/repos/acme/repo/issues", in_progress_opts}
    assert Keyword.get(in_progress_opts, :params)[:labels] == "status:in-progress"
    assert Keyword.get(in_progress_opts, :params)[:state] == "open"
  end

  test "fetch_candidate_issues_for_test handles pagination, malformed entries, and status failures" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
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

  test "fetch_candidate_issues_for_test honors open/closed entries in active states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_active_states: ["closed", "open"]
    )

    request_fun = fn :get, _url, opts ->
      params = Keyword.fetch!(opts, :params)
      send(self(), {:params, params})

      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => 444,
             "number" => 44,
             "title" => "Open candidate",
             "body" => "Body",
             "state" => "open",
             "html_url" => "https://github.com/acme/repo/issues/44",
             "labels" => [],
             "assignees" => []
           }
         ]
       }}
    end

    assert {:ok, [%Issue{id: "44", state: "open"}]} = Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:params, params}
    assert params[:state] == "open"
    refute Keyword.has_key?(params, :labels)
    refute_receive {:params, _}
  end

  test "fetch_candidate_issues_for_test returns no candidates when active_states is explicitly empty" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: []
    )

    request_fun = fn :get, _url, _opts ->
      flunk("fetch_candidate_issues_for_test should not query GitHub when active_states is explicitly empty")
    end

    assert {:ok, []} = Client.fetch_candidate_issues_for_test(request_fun)
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
      tracker_api_token: "  gh-token  "
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

  test "build_repo_context derives the correct REST base URL from the configured GitHub endpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com/api/graphql"
    )

    assert {:ok, context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert context.rest_endpoint == "https://ghe.example.com/api/v3"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com/api/v3/graphql"
    )

    assert {:ok, v3_context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert v3_context.rest_endpoint == "https://ghe.example.com/api/v3"
  end

  test "build_repo_context uses env tokens and covers REST endpoint fallbacks" do
    restore_env("GITHUB_TOKEN", "env-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: nil
    )

    assert {:ok, context} = Client.build_repo_context("acme", "repo")
    assert context.api_key == "env-token"
    assert context.rest_endpoint == "https://api.github.com"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://api.linear.app/graphql"
    )

    assert {:ok, linear_context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert linear_context.rest_endpoint == "https://api.github.com"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com"
    )

    assert {:ok, pathless_context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert pathless_context.rest_endpoint == "https://ghe.example.com"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com/custom/path"
    )

    assert {:ok, passthrough_context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert passthrough_context.rest_endpoint == "https://ghe.example.com/custom/path"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "not a url"
    )

    assert {:ok, invalid_context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert invalid_context.rest_endpoint == "https://api.github.com"
  end

  test "build_repo_context falls back to the default REST endpoint when workflow config is invalid" do
    valid_workflow = Workflow.workflow_file_path()
    invalid_workflow = Path.join(Path.dirname(valid_workflow), "BROKEN_WORKFLOW.md")
    File.write!(invalid_workflow, "---\ntracker: [\n---\nBroken prompt\n")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(invalid_workflow)

    assert {:error, _reason} = Config.settings()
    assert {:ok, context} = Client.build_repo_context("acme", "repo", "gh-token")
    assert context.rest_endpoint == "https://api.github.com"

    Workflow.set_workflow_file_path(valid_workflow)
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "build_repo_context honors an explicit REST endpoint override" do
    valid_workflow = Workflow.workflow_file_path()
    invalid_workflow = Path.join(Path.dirname(valid_workflow), "BROKEN_WORKFLOW_OVERRIDE.md")
    File.write!(invalid_workflow, "---\ntracker: [\n---\nBroken prompt\n")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(invalid_workflow)

    assert {:error, _reason} = Config.settings()

    assert {:ok, context} =
             Client.build_repo_context("acme", "repo", "gh-token", rest_endpoint: "https://ghe.example.com/api/v3")

    assert context.rest_endpoint == "https://ghe.example.com/api/v3"

    Workflow.set_workflow_file_path(valid_workflow)
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "build_repo_context ignores blank REST endpoint overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com/api/graphql"
    )

    assert {:ok, context} =
             Client.build_repo_context("acme", "repo", "gh-token", rest_endpoint: "   ")

    assert context.rest_endpoint == "https://ghe.example.com/api/v3"
  end

  test "fetch_candidate_issues_for_test uses the configured REST endpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: "https://ghe.example.com/api/graphql",
      tracker_active_states: ["status:ready"]
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
             "html_url" => "https://ghe.example.com/acme/repo/issues/7",
             "labels" => [%{"name" => "status:ready"}],
             "assignees" => []
           }
         ]
       }}
    end

    assert {:ok, [%Issue{id: "7", number: 7, state: "status:ready"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, :get, "https://ghe.example.com/api/v3/repos/acme/repo/issues", _opts}
  end

  test "get_default_branch_for_test uses the repository REST endpoint" do
    repo = %{
      repo_owner: "acme",
      repo_name: "repo",
      api_key: "gh-token",
      rest_endpoint: "https://ghe.example.com/api"
    }

    request_fun = fn method, url, _opts ->
      send(self(), {:request, method, url})
      {:ok, %{status: 200, body: %{"default_branch" => "trunk"}}}
    end

    assert {:ok, "trunk"} = Client.get_default_branch_for_test(repo, request_fun)
    assert_receive {:request, :get, "https://ghe.example.com/api/repos/acme/repo"}
  end

  test "list_collaborators_for_test paginates collaborator pages" do
    repo = %{
      repo_owner: "acme",
      repo_name: "repo",
      api_key: "gh-token",
      rest_endpoint: "https://ghe.example.com/api"
    }

    request_fun = fn method, url, opts ->
      params = Keyword.fetch!(opts, :params)
      send(self(), {:request, method, url, params})

      body =
        case params[:page] do
          1 -> Enum.map(1..100, fn number -> %{"login" => "user-#{number}"} end)
          2 -> [%{"login" => "user-101"}]
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, collaborators} = Client.list_collaborators_for_test(repo, request_fun)
    assert length(collaborators) == 101
    assert "user-101" in collaborators

    assert_receive {:request, :get, "https://ghe.example.com/api/repos/acme/repo/collaborators", [per_page: 100, page: 1]}
    assert_receive {:request, :get, "https://ghe.example.com/api/repos/acme/repo/collaborators", [per_page: 100, page: 2]}
    refute_receive {:request, :get, _, [per_page: 100, page: 3]}
  end

  test "repo API wrapper helpers short-circuit before network when auth is missing" do
    repo = %{repo_owner: "acme", repo_name: "repo", api_key: nil}

    assert {:error, {:github_api_request, :missing_github_api_token}} = Client.list_labels(repo)
    assert {:error, {:github_api_request, :missing_github_api_token}} = Client.create_label(repo, %{"name" => "status:ready"})
    assert {:error, :missing_github_api_token} = Client.list_collaborators(repo)
    assert {:error, :missing_github_api_token} = Client.get_branch_protection(repo, "main")
    assert {:error, {:github_api_request, :missing_github_api_token}} = Client.put_branch_protection(repo, "main", %{})
    assert {:error, {:github_api_request, :missing_github_api_token}} = Client.get_default_branch(repo)
  end

  test "label helper wrappers expose success and failure branches" do
    repo = %{repo_owner: "acme", repo_name: "repo", api_key: "gh-token", rest_endpoint: "https://ghe.example.com/api"}

    assert {:ok, [%{"name" => "status:ready"}]} =
             Client.list_labels_for_test(repo, fn method, url, _opts ->
               send(self(), {:list_labels_ok, method, url})
               {:ok, %{status: 200, body: [%{"name" => "status:ready"}]}}
             end)

    assert_receive {:list_labels_ok, :get, "https://ghe.example.com/api/repos/acme/repo/labels"}

    assert {:error, {:github_api_status, 500}} =
             Client.list_labels_for_test(repo, fn _method, _url, _opts ->
               {:ok, %{status: 500, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.list_labels_for_test(repo, fn _method, _url, _opts -> {:error, :closed} end)

    assert :ok =
             Client.create_label_for_test(repo, %{"name" => "status:ready"}, fn method, url, opts ->
               send(self(), {:create_label_ok, method, url, opts[:json]})
               {:ok, %{status: 201, body: %{}}}
             end)

    assert_receive {:create_label_ok, :post, "https://ghe.example.com/api/repos/acme/repo/labels", %{"name" => "status:ready"}}

    assert :ok =
             Client.create_label_for_test(repo, %{"name" => "status:ready"}, fn _method, _url, _opts ->
               {:ok, %{status: 422, body: %{}}}
             end)

    assert {:error, {:github_api_status, 503}} =
             Client.create_label_for_test(repo, %{"name" => "status:ready"}, fn _method, _url, _opts ->
               {:ok, %{status: 503, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.create_label_for_test(repo, %{"name" => "status:ready"}, fn _method, _url, _opts ->
               {:error, :closed}
             end)
  end

  test "collaborator and branch protection helper wrappers expose success and failure branches" do
    repo = %{repo_owner: "acme", repo_name: "repo", api_key: "gh-token"}

    assert {:error, {:github_api_status, 502}} =
             Client.list_collaborators_for_test(repo, fn _method, _url, _opts ->
               {:ok, %{status: 502, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.list_collaborators_for_test(repo, fn _method, _url, _opts -> {:error, :closed} end)

    assert {:ok, %{"required_status_checks" => %{}}} =
             Client.get_branch_protection_for_test(repo, "main", fn method, url, _opts ->
               send(self(), {:get_branch_ok, method, url})
               {:ok, %{status: 200, body: %{"required_status_checks" => %{}}}}
             end)

    assert_receive {:get_branch_ok, :get, "https://api.github.com/repos/acme/repo/branches/main/protection"}

    assert {:ok, nil} =
             Client.get_branch_protection_for_test(repo, "main", fn _method, _url, _opts ->
               {:ok, %{status: 404, body: %{}}}
             end)

    assert {:error, {:github_api_status, 500}} =
             Client.get_branch_protection_for_test(repo, "main", fn _method, _url, _opts ->
               {:ok, %{status: 500, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.get_branch_protection_for_test(repo, "main", fn _method, _url, _opts -> {:error, :closed} end)

    assert :ok =
             Client.put_branch_protection_for_test(repo, "release/1.0", %{"required_status_checks" => nil}, fn method, url, opts ->
               send(self(), {:put_branch_ok, method, url, opts[:json]})
               {:ok, %{status: 200, body: %{}}}
             end)

    assert_receive {:put_branch_ok, :put, "https://api.github.com/repos/acme/repo/branches/release%2F1.0/protection", %{"required_status_checks" => nil}}

    assert {:error, {:github_api_status, 500}} =
             Client.put_branch_protection_for_test(repo, "main", %{}, fn _method, _url, _opts ->
               {:ok, %{status: 500, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.put_branch_protection_for_test(repo, "main", %{}, fn _method, _url, _opts -> {:error, :closed} end)
  end

  test "default branch helper wrappers expose success and failure branches" do
    repo = %{repo_owner: "acme", repo_name: "repo", api_key: "gh-token"}

    assert {:ok, "main"} =
             Client.get_default_branch_for_test(repo, fn method, url, _opts ->
               send(self(), {:default_branch_ok, method, url})
               {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
             end)

    assert_receive {:default_branch_ok, :get, "https://api.github.com/repos/acme/repo"}

    assert {:error, {:github_api_request, :missing_default_branch}} =
             Client.get_default_branch_for_test(repo, fn _method, _url, _opts ->
               {:ok, %{status: 200, body: %{}}}
             end)

    assert {:error, {:github_api_status, 503}} =
             Client.get_default_branch_for_test(repo, fn _method, _url, _opts ->
               {:ok, %{status: 503, body: %{}}}
             end)

    assert {:error, {:github_api_request, :closed}} =
             Client.get_default_branch_for_test(repo, fn _method, _url, _opts -> {:error, :closed} end)
  end

  test "graphql/3 uses the default GitHub endpoint when tracker endpoint is nil" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_endpoint: nil
    )

    assert {:ok, %{"data" => %{"ok" => true}}} =
             Client.graphql("query Ping { ok }", %{},
               request_fun: fn method, url, _opts ->
                 send(self(), {:graphql_request, method, url})
                 {:ok, %{status: 200, body: %{"data" => %{"ok" => true}}}}
               end
             )

    assert_receive {:graphql_request, :post, "https://api.github.com/graphql"}
  end

  test "public wrappers return fast validation errors without network dependencies" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)

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
    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)

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
      tracker_project_slug: "acme/repo",
      tracker_repo_owner: nil,
      tracker_repo_name: nil,
      tracker_api_token: "gh-token"
    )

    assert {:error, :missing_github_repo_owner} =
             Client.fetch_candidate_issues_for_test(fn _method, _url, _opts ->
               flunk("project_slug must not bypass missing repo_owner validation")
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

  test "fetch_issues_by_states_for_test supports open/closed issue state filters" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    request_fun = fn :get, _url, opts ->
      params = Keyword.fetch!(opts, :params)
      send(self(), {:params, params})

      body =
        case params[:state] do
          "closed" ->
            [
              %{
                "id" => 222,
                "number" => 22,
                "title" => "Closed issue",
                "body" => "Done",
                "state" => "closed",
                "html_url" => "https://github.com/acme/repo/issues/22",
                "labels" => [%{"name" => "status:in-progress"}],
                "assignees" => []
              }
            ]

          "open" ->
            [
              %{
                "id" => 333,
                "number" => 33,
                "title" => "Open issue",
                "body" => "Todo",
                "state" => "open",
                "html_url" => "https://github.com/acme/repo/issues/33",
                "labels" => [],
                "assignees" => []
              }
            ]
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%Issue{id: "22", state: "closed"}, %Issue{id: "33", state: "open"}]} =
             Client.fetch_issues_by_states_for_test(["Closed", "Open"], request_fun)

    assert_receive {:params, params_closed}
    assert params_closed[:state] == "closed"
    refute Keyword.has_key?(params_closed, :labels)

    assert_receive {:params, params_open}
    assert params_open[:state] == "open"
    refute Keyword.has_key?(params_open, :labels)
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
          assert Enum.sort(labels) == ["infra", "status:in-progress"]
          {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok = Client.update_issue_state_for_test("42", "status:in-progress", success)

    invalid_transition = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: flunk("patch should not run")
    end

    assert {:error, {:invalid_issue_state_transition, "status:ready", "status:review"}} =
             Client.update_issue_state_for_test("42", "status:review", invalid_transition)

    assert {:error, {:invalid_issue_state_transition, "status:ready", "bogus"}} =
             Client.update_issue_state_for_test("42", "bogus", invalid_transition)

    missing_issue = fn method, _url, _opts ->
      if method == :get, do: {:ok, %{status: 404, body: %{}}}, else: flunk("patch should not run")
    end

    assert {:error, :issue_not_found} = Client.update_issue_state_for_test("42", "status:in-progress", missing_issue)

    patch_failure = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: {:ok, %{status: 422, body: %{}}}
    end

    assert {:error, {:github_api_status, 422}} =
             Client.update_issue_state_for_test("42", "status:in-progress", patch_failure)

    request_failure = fn _method, _url, _opts -> {:error, :closed} end

    assert {:error, {:github_api_request, :closed}} =
             Client.update_issue_state_for_test("42", "status:in-progress", request_failure)

    malformed_patch = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: :unexpected
    end

    assert {:error, :issue_update_failed} =
             Client.update_issue_state_for_test("42", "status:in-progress", malformed_patch)

    get_status_failure = fn method, _url, _opts ->
      if method == :get, do: {:ok, %{status: 500, body: %{}}}, else: flunk("patch should not run")
    end

    assert {:error, {:github_api_status, 500}} =
             Client.update_issue_state_for_test("42", "status:in-progress", get_status_failure)

    assert {:error, :invalid_github_issue_id} =
             Client.update_issue_state_for_test("bad", "status:in-progress", success)
  end

  test "update_issue_state_for_test allows initializing triage and keeping the same status label" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    open_to_triage = fn method, _url, opts ->
      case method do
        :get ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => 7,
               "number" => 7,
               "title" => "Issue 7",
               "body" => "Body",
               "state" => "open",
               "html_url" => "https://github.com/acme/repo/issues/7",
               "labels" => [%{"name" => "infra"}],
               "assignees" => []
             }
           }}

        :patch ->
          assert Enum.sort(get_in(opts, [:json, "labels"])) == ["infra", "status:triage"]
          {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok = Client.update_issue_state_for_test("7", "status:triage", open_to_triage)

    same_state = fn method, _url, opts ->
      case method do
        :get ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => 9,
               "number" => 9,
               "title" => "Issue 9",
               "body" => "Body",
               "state" => "open",
               "html_url" => "https://github.com/acme/repo/issues/9",
               "labels" => [%{"name" => "status:review"}, %{"name" => "infra"}],
               "assignees" => []
             }
           }}

        :patch ->
          assert Enum.sort(get_in(opts, [:json, "labels"])) == ["infra", "status:review"]
          {:ok, %{status: 200, body: %{}}}
      end
    end

    assert :ok = Client.update_issue_state_for_test("9", "status:review", same_state)
  end

  test "update_issue_state_for_test rejects malformed issues with missing current state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    malformed_issue = fn method, _url, _opts ->
      if method == :get do
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => 11,
             "number" => 11,
             "title" => "Issue 11",
             "body" => "Body",
             "state" => nil,
             "html_url" => "https://github.com/acme/repo/issues/11",
             "labels" => [%{"name" => "infra"}],
             "assignees" => []
           }
         }}
      else
        flunk("patch should not run")
      end
    end

    assert {:error, {:invalid_issue_state_transition, nil, "status:review"}} =
             Client.update_issue_state_for_test("11", "status:review", malformed_issue)
  end

  test "update_issue_state_for_test normalizes non-binary current states before rejecting them" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token"
    )

    malformed_issue = fn method, _url, _opts ->
      if method == :get do
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => 12,
             "number" => 12,
             "title" => "Issue 12",
             "body" => "Body",
             "state" => 123,
             "html_url" => "https://github.com/acme/repo/issues/12",
             "labels" => [%{"name" => "infra"}],
             "assignees" => []
           }
         }}
      else
        flunk("patch should not run")
      end
    end

    assert {:error, {:invalid_issue_state_transition, "123", "status:review"}} =
             Client.update_issue_state_for_test("12", "status:review", malformed_issue)
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

    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)

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
