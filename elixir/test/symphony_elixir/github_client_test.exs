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

    assert {:error, {:github_api_status, 422, %{"message" => "unsupported"}}} =
             Client.put_branch_protection_for_test(repo, "main", %{}, fn _method, _url, _opts ->
               {:ok, %{status: 422, body: %{"message" => "unsupported"}}}
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

  test "new public github wrappers fail fast without auth and without issuing network requests" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)

    write_github_tracker_workflow(tracker_api_token: nil)

    assert {:error, :missing_github_api_token} = Client.has_actionable_pr_feedback?("7", [])
    assert {:error, :missing_github_api_token} = Client.has_pr_approval?("7")
    assert {:error, :missing_github_api_token} = Client.check_auto_merge_readiness("7")
    assert {:error, :missing_github_api_token} = Client.auto_merge_pr(7)
  end

  test "has_actionable_pr_feedback_for_test handles no-pr, success, and API error paths" do
    write_github_tracker_workflow()

    no_pr_request = fn :get, url, _opts ->
      assert String.ends_with?(url, "/pulls")
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok, false} = Client.has_actionable_pr_feedback_for_test("7", ["reviewer-1"], no_pr_request)
    assert {:error, :invalid_github_issue_id} = Client.has_actionable_pr_feedback_for_test("bad-id", [], no_pr_request)

    review_allowlist_hit = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 42, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/42/comments") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "Reviewer-1"}, "body" => "needs change"}]}}

        String.ends_with?(url, "/issues/42/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, true} = Client.has_actionable_pr_feedback_for_test("7", ["reviewer-1"], review_allowlist_hit)
    assert {:ok, false} = Client.has_actionable_pr_feedback_for_test("7", ["other-reviewer"], review_allowlist_hit)

    issue_allowlist_hit = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 43, "body" => "Closes #7"}]}}

        String.ends_with?(url, "/pulls/43/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/issues/43/comments") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "Maintainer"}, "body" => "follow up"}]}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, true} = Client.has_actionable_pr_feedback_for_test("7", ["maintainer"], issue_allowlist_hit)

    review_status_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 44, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/44/comments") ->
          {:ok, %{status: 500, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_status, 500}} =
             Client.has_actionable_pr_feedback_for_test("7", ["anyone"], review_status_error)

    review_transport_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 46, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/46/comments") ->
          {:error, :timeout}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_request, :timeout}} =
             Client.has_actionable_pr_feedback_for_test("7", ["anyone"], review_transport_error)

    issue_transport_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 45, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/45/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/issues/45/comments") ->
          {:error, :closed}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_request, :closed}} =
             Client.has_actionable_pr_feedback_for_test("7", ["anyone"], issue_transport_error)

    issue_status_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 47, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/47/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/issues/47/comments") ->
          {:ok, %{status: 502, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_status, 502}} =
             Client.has_actionable_pr_feedback_for_test("7", ["anyone"], issue_status_error)

    pulls_transport_error = fn :get, url, _opts ->
      assert String.ends_with?(url, "/pulls")
      {:error, :closed}
    end

    assert {:error, {:github_api_request, :closed}} =
             Client.has_actionable_pr_feedback_for_test("7", ["anyone"], pulls_transport_error)
  end

  test "has_pr_approval_for_test handles approval states, no-pr, and error paths" do
    write_github_tracker_workflow()

    no_pr_request = fn :get, url, _opts ->
      assert String.ends_with?(url, "/pulls")
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok, false} = Client.has_pr_approval_for_test("7", no_pr_request)

    approved_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 50, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/50/reviews") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"user" => %{"login" => "reviewer"}, "state" => "COMMENTED"},
               %{"user" => %{"login" => "reviewer"}, "state" => "APPROVED"}
             ]
           }}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, true} = Client.has_pr_approval_for_test("7", approved_request)

    not_approved_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 51, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/51/reviews") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"user" => %{"login" => "reviewer"}, "state" => "APPROVED"},
               %{"user" => %{"login" => "reviewer"}, "state" => "CHANGES_REQUESTED"}
             ]
           }}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, false} = Client.has_pr_approval_for_test("7", not_approved_request)

    paginated_not_approved_request = fn :get, url, opts ->
      params = Keyword.get(opts, :params, [])

      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 54, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/54/reviews") and Keyword.get(params, :page) == 1 ->
          filler =
            Enum.map(1..99, fn n ->
              %{"user" => %{"login" => "reviewer-#{n}"}, "state" => "COMMENTED"}
            end)

          {:ok,
           %{
             status: 200,
             body: [%{"user" => %{"login" => "reviewer"}, "state" => "APPROVED"} | filler]
           }}

        String.ends_with?(url, "/pulls/54/reviews") and Keyword.get(params, :page) == 2 ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "reviewer"}, "state" => "CHANGES_REQUESTED"}]}}

        true ->
          flunk("unexpected URL #{url} params=#{inspect(params)}")
      end
    end

    assert {:ok, false} = Client.has_pr_approval_for_test("7", paginated_not_approved_request)

    review_status_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 52, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/52/reviews") ->
          {:ok, %{status: 500, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_status, 500}} = Client.has_pr_approval_for_test("7", review_status_error)

    review_transport_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 53, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/53/reviews") ->
          {:error, :timeout}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_request, :timeout}} =
             Client.has_pr_approval_for_test("7", review_transport_error)
  end

  test "check_auto_merge_readiness_for_test covers ready, blocker, and error branches" do
    write_github_tracker_workflow()

    no_pr_request = fn :get, url, _opts ->
      assert String.ends_with?(url, "/pulls")
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok, :needs_agent, ["no linked PR found"]} =
             Client.check_auto_merge_readiness_for_test("7", no_pr_request)

    pulls_status_error = fn :get, url, _opts ->
      assert String.ends_with?(url, "/pulls")
      {:ok, %{status: 500, body: %{}}}
    end

    assert {:error, {:github_api_status, 500}} =
             Client.check_auto_merge_readiness_for_test("7", pulls_status_error)

    pr_request_failure = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 60, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/60") ->
          {:error, :closed}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_request, :closed}} =
             Client.check_auto_merge_readiness_for_test("7", pr_request_failure)

    ready_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 61, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/61") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "mergeable_state" => "clean",
               "head" => "not-a-map",
               "title" => "Ready PR",
               "body" => "body"
             }
           }}

        String.ends_with?(url, "/pulls/61/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/61/comments") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"user" => %{"login" => "github-actions[bot]"}, "body" => "automated", "created_at" => "2026-03-01T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "@codex review", "created_at" => "2026-03-01T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "@codex please review this PR", "created_at" => "2026-03-01T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "## Codex Review", "created_at" => "2026-03-01T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "please fix", "created_at" => "2026-03-01T00:00:00Z"},
               %{"user" => %{"login" => "siaan-bot"}, "body" => "[siaan] fixed", "created_at" => "2026-03-02T00:00:00Z"}
             ]
           }}

        String.ends_with?(url, "/pulls/61/comments") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"id" => 1, "user" => %{"login" => "reviewer"}, "body" => "nit"},
               %{"id" => 2, "in_reply_to_id" => 1, "user" => %{"login" => "siaan-bot"}, "body" => "[siaan] addressed"}
             ]
           }}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :ready, 61} = Client.check_auto_merge_readiness_for_test("7", ready_request)

    blocked_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 62, "body" => "Closes #7"}]}}

        String.ends_with?(url, "/pulls/62") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "mergeable_state" => "CONFLICTING",
               "head" => %{"sha" => "abc123"},
               "title" => "Blocked PR",
               "body" => "body"
             }
           }}

        String.ends_with?(url, "/commits/abc123/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => [%{"status" => "queued"}]}}}

        String.ends_with?(url, "/pulls/62/reviews") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/issues/62/comments") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"user" => %{"login" => "siaan-bot"}, "body" => "[siaan] older reply", "created_at" => "2026-03-02T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "new blocker", "created_at" => "2026-03-03T00:00:00Z"}
             ]
           }}

        String.ends_with?(url, "/pulls/62/comments") ->
          {:ok, %{status: 200, body: [%{"id" => 9, "user" => %{"login" => "reviewer"}, "body" => "still open"}]}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["merge conflicts", "CI checks pending", "no PR approval", "unanswered PR comments", "unanswered review comments"]} =
             Client.check_auto_merge_readiness_for_test("7", blocked_request)

    ci_failed_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 63, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/63") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-63"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-63/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "failure"}]}}}

        String.ends_with?(url, "/pulls/63/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/63/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/63/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["CI checks failed"]} = Client.check_auto_merge_readiness_for_test("7", ci_failed_request)

    ci_green_completed_checks_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 69, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/69") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-69"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-69/check-runs") ->
          {:ok,
           %{
             status: 200,
             body: %{"check_runs" => [%{"status" => "completed", "conclusion" => "success"}]}
           }}

        String.ends_with?(url, "/pulls/69/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/69/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/69/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :ready, 69} =
             Client.check_auto_merge_readiness_for_test("7", ci_green_completed_checks_request)

    head_nil_ready_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 79, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/79") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => nil, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/pulls/79/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/79/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/79/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :ready, 79} =
             Client.check_auto_merge_readiness_for_test("7", head_nil_ready_request)

    ci_status_error_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 80, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/80") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-80"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-80/check-runs") ->
          {:ok, %{status: 500, body: %{}}}

        String.ends_with?(url, "/pulls/80/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/80/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/80/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check CI"]} =
             Client.check_auto_merge_readiness_for_test("7", ci_status_error_request)

    ci_error_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 64, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/64") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-64"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-64/check-runs") ->
          {:error, :timeout}

        String.ends_with?(url, "/pulls/64/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/64/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/64/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check CI"]} = Client.check_auto_merge_readiness_for_test("7", ci_error_request)

    pr_status_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 81, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/81") ->
          {:ok, %{status: 503, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:github_api_status, 503}} =
             Client.check_auto_merge_readiness_for_test("7", pr_status_error)

    approval_error_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 65, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/65") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-65"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-65/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/65/reviews") ->
          {:ok, %{status: 500, body: %{}}}

        String.ends_with?(url, "/issues/65/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/65/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check approval"]} =
             Client.check_auto_merge_readiness_for_test("7", approval_error_request)

    comments_error_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 66, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/66") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-66"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-66/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/66/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/66/comments") ->
          {:ok, %{status: 500, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check comments"]} =
             Client.check_auto_merge_readiness_for_test("7", comments_error_request)

    bad_issue_comments_transport = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 67, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/67") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-67"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-67/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/67/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/67/comments") ->
          {:error, :broken_pipe}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check comments"]} =
             Client.check_auto_merge_readiness_for_test("7", bad_issue_comments_transport)

    bad_review_comments_transport = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 68, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/68") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-68"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-68/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/68/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/68/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/68/comments") ->
          {:error, :closed}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check comments"]} =
             Client.check_auto_merge_readiness_for_test("7", bad_review_comments_transport)

    review_comments_status_error = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 84, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/84") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-84"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-84/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/84/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/84/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/84/comments") ->
          {:ok, %{status: 500, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["failed to check comments"]} =
             Client.check_auto_merge_readiness_for_test("7", review_comments_status_error)

    unanswered_without_reply_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 82, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/82") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-82"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-82/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/82/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/82/comments") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "reviewer"}, "body" => "still blocked"}]}}

        String.ends_with?(url, "/pulls/82/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["unanswered PR comments"]} =
             Client.check_auto_merge_readiness_for_test("7", unanswered_without_reply_request)

    missing_timestamp_after_reply_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 83, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/83") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-83"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-83/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/83/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/83/comments") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"user" => %{"login" => "siaan-bot"}, "body" => "[siaan] checked", "created_at" => "2026-03-03T00:00:00Z"},
               %{"user" => %{"login" => "reviewer"}, "body" => "timestamp missing"}
             ]
           }}

        String.ends_with?(url, "/pulls/83/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["unanswered PR comments"]} =
             Client.check_auto_merge_readiness_for_test("7", missing_timestamp_after_reply_request)

    non_allowlist_comments_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 85, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/85") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-85"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-85/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/85/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/85/comments") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "outsider"}, "body" => "random note"}]}}

        String.ends_with?(url, "/pulls/85/comments") ->
          {:ok, %{status: 200, body: [%{"id" => 100, "user" => %{"login" => "outsider"}, "body" => "nit"}]}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :ready, 85} =
             Client.check_auto_merge_readiness_for_test("7", non_allowlist_comments_request)

    paginated_pr_search_request = fn :get, url, opts ->
      params = Keyword.get(opts, :params, [])

      cond do
        String.ends_with?(url, "/pulls") and Keyword.get(params, :page) == 1 ->
          filler =
            Enum.map(1..100, fn n ->
              %{"number" => 1_000 + n, "body" => "misc body #{n}"}
            end)

          {:ok, %{status: 200, body: filler}}

        String.ends_with?(url, "/pulls") and Keyword.get(params, :page) == 2 ->
          {:ok, %{status: 200, body: [%{"number" => 86, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/86") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-86"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-86/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/86/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/86/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/86/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url} params=#{inspect(params)}")
      end
    end

    assert {:ok, :ready, 86} =
             Client.check_auto_merge_readiness_for_test("7", paginated_pr_search_request)

    issue_number_boundary_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"number" => 90, "body" => "closes #70"},
               %{"number" => 91, "body" => "closes #7"}
             ]
           }}

        String.ends_with?(url, "/pulls/91") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-91"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-91/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/91/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/91/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/91/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :ready, 91} =
             Client.check_auto_merge_readiness_for_test("7", issue_number_boundary_request)

    dirty_conflict_state_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 92, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/92") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "dirty", "head" => %{"sha" => "sha-92"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-92/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/92/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/92/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/92/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["merge conflicts"]} =
             Client.check_auto_merge_readiness_for_test("7", dirty_conflict_state_request)

    follow_up_after_siaan_review_comment_request = fn :get, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 87, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/87") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-87"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-87/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/87/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/87/comments") ->
          {:ok, %{status: 200, body: []}}

        String.ends_with?(url, "/pulls/87/comments") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"id" => 20, "user" => %{"login" => "reviewer"}, "body" => "first", "created_at" => "2026-03-01T00:00:00Z"},
               %{"id" => 21, "in_reply_to_id" => 20, "user" => %{"login" => "siaan-bot"}, "body" => "[siaan] fixed", "created_at" => "2026-03-02T00:00:00Z"},
               %{"id" => 22, "in_reply_to_id" => 20, "user" => %{"login" => "reviewer"}, "body" => "one more thing", "created_at" => "2026-03-03T00:00:00Z"}
             ]
           }}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:ok, :needs_agent, ["unanswered review comments"]} =
             Client.check_auto_merge_readiness_for_test("7", follow_up_after_siaan_review_comment_request)

    paginated_issue_comments_request = fn :get, url, opts ->
      params = Keyword.get(opts, :params, [])

      cond do
        String.ends_with?(url, "/pulls") ->
          {:ok, %{status: 200, body: [%{"number" => 88, "body" => "closes #7"}]}}

        String.ends_with?(url, "/pulls/88") ->
          {:ok,
           %{
             status: 200,
             body: %{"mergeable_state" => "clean", "head" => %{"sha" => "sha-88"}, "title" => "t", "body" => "b"}
           }}

        String.ends_with?(url, "/commits/sha-88/check-runs") ->
          {:ok, %{status: 200, body: %{"check_runs" => []}}}

        String.ends_with?(url, "/pulls/88/reviews") ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "maintainer"}, "state" => "APPROVED"}]}}

        String.ends_with?(url, "/issues/88/comments") and Keyword.get(params, :page) == 1 ->
          filler =
            Enum.map(1..100, fn n ->
              %{"user" => %{"login" => "outsider"}, "body" => "n#{n}"}
            end)

          {:ok, %{status: 200, body: filler}}

        String.ends_with?(url, "/issues/88/comments") and Keyword.get(params, :page) == 2 ->
          {:ok, %{status: 200, body: [%{"user" => %{"login" => "reviewer"}, "body" => "blocker", "created_at" => "2026-03-03T00:00:00Z"}]}}

        String.ends_with?(url, "/pulls/88/comments") ->
          {:ok, %{status: 200, body: []}}

        true ->
          flunk("unexpected URL #{url} params=#{inspect(params)}")
      end
    end

    assert {:ok, :needs_agent, ["unanswered PR comments"]} =
             Client.check_auto_merge_readiness_for_test("7", paginated_issue_comments_request)

    bad_issue_id_request = fn _method, _url, _opts ->
      flunk("request function should not be called for invalid issue ids")
    end

    assert {:error, :invalid_github_issue_id} =
             Client.check_auto_merge_readiness_for_test("invalid", bad_issue_id_request)
  end

  test "auto_merge_pr_for_test handles update and merge result branches" do
    write_github_tracker_workflow()

    success_request = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/70/update-branch") ->
          {:ok, %{status: 202, body: %{}}}

        String.ends_with?(url, "/pulls/70/merge") ->
          {:ok, %{status: 200, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert :ok = Client.auto_merge_pr_for_test(70, success_request)

    already_updated_request = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/71/update-branch") ->
          {:ok, %{status: 422, body: %{}}}

        String.ends_with?(url, "/pulls/71/merge") ->
          {:ok, %{status: 200, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert :ok = Client.auto_merge_pr_for_test(71, already_updated_request)

    update_transport_error = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/72/update-branch") ->
          {:error, :network_down}

        String.ends_with?(url, "/pulls/72/merge") ->
          {:ok, %{status: 200, body: %{}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert :ok = Client.auto_merge_pr_for_test(72, update_transport_error)

    merge_status_map_body = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/73/update-branch") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/pulls/73/merge") ->
          {:ok, %{status: 405, body: %{"message" => "merge not allowed"}}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:merge_failed, 405, "merge not allowed"}} = Client.auto_merge_pr_for_test(73, merge_status_map_body)

    merge_status_non_map_body = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/74/update-branch") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/pulls/74/merge") ->
          {:ok, %{status: 409, body: "conflict"}}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:merge_failed, 409, "\"conflict\""}} = Client.auto_merge_pr_for_test(74, merge_status_non_map_body)

    merge_transport_error = fn :put, url, _opts ->
      cond do
        String.ends_with?(url, "/pulls/75/update-branch") ->
          {:ok, %{status: 200, body: %{}}}

        String.ends_with?(url, "/pulls/75/merge") ->
          {:error, :closed}

        true ->
          flunk("unexpected URL #{url}")
      end
    end

    assert {:error, {:merge_request_failed, :closed}} = Client.auto_merge_pr_for_test(75, merge_transport_error)
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

  defp write_github_tracker_workflow(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "github",
          tracker_repo_owner: "acme",
          tracker_repo_name: "repo",
          tracker_api_token: "gh-token",
          allowlist: ["reviewer", "maintainer"]
        ],
        overrides
      )
    )
  end
end
