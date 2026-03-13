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

    status_failure = fn _method, _url, _opts -> {:ok, %{status: 503, body: %{}}} end

    assert {:error, {:github_api_status, 503}} =
             Client.graphql("query Viewer { viewer { login } }", %{}, request_fun: status_failure)
  end
end
