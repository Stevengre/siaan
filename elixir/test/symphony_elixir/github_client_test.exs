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

  test "fetch_candidate_issues_for_test falls back to ready label when active_states is empty" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: []
    )

    request_fun = fn :get, _url, opts ->
      send(self(), {:params, Keyword.fetch!(opts, :params)})

      {:ok,
       %{
         status: 200,
         body: [
           %{
             "id" => 555,
             "number" => 55,
             "title" => "Ready candidate",
             "body" => "Body",
             "state" => "open",
             "html_url" => "https://github.com/acme/repo/issues/55",
             "labels" => [%{"name" => "status:ready"}],
             "assignees" => []
           }
         ]
       }}
    end

    assert {:ok, [%Issue{id: "55", state: "status:ready"}]} = Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:params, params}
    assert params[:state] == "open"
    assert params[:labels] == "status:ready"
  end

  test "fetch_candidate_issues_for_test derives REST issue URLs from tracker endpoint variants" do
    request_fun = fn :get, url, _opts ->
      send(self(), {:url, url})
      {:ok, %{status: 200, body: []}}
    end

    endpoint_cases = [
      {"https://ghe.example.com/api/graphql", "https://ghe.example.com/api/v3/repos/acme/repo/issues"},
      {"https://proxy.example.com/enterprise/graphql", "https://proxy.example.com/enterprise/repos/acme/repo/issues"},
      {"https://proxy.example.com/api/v3", "https://proxy.example.com/api/v3/repos/acme/repo/issues"},
      {"https://proxy.example.com", "https://proxy.example.com/repos/acme/repo/issues"},
      {"not-a-url", "https://api.github.com/repos/acme/repo/issues"}
    ]

    Enum.each(endpoint_cases, fn {endpoint, expected_url} ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo_owner: "acme",
        tracker_repo_name: "repo",
        tracker_api_token: "gh-token",
        tracker_endpoint: endpoint,
        tracker_ready_label: "status:ready",
        tracker_active_states: ["status:ready"]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(request_fun)
      assert_receive {:url, ^expected_url}
    end)
  end

  test "fetch_candidate_issues_for_test reuses cached issue pages when GitHub returns 304" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
    )

    request_fun = fn :get, _url, opts ->
      params = Keyword.fetch!(opts, :params)
      headers = Keyword.fetch!(opts, :headers)
      if_none_match = Enum.find_value(headers, &header_value(&1, "if-none-match"))

      send(self(), {:request, params[:page], if_none_match})

      case if_none_match do
        nil ->
          {:ok,
           %{
             status: 200,
             headers: [{"etag", "\"etag-ready-page-1\""}],
             body: [
               %{
                 "id" => 770,
                 "number" => 77,
                 "title" => "Ready candidate",
                 "body" => "Body",
                 "state" => "open",
                 "html_url" => "https://github.com/acme/repo/issues/77",
                 "labels" => [%{"name" => "status:ready"}],
                 "assignees" => []
               }
             ]
           }}

        "\"etag-ready-page-1\"" ->
          {:ok, %{status: 304, headers: [{"etag", "\"etag-ready-page-1\""}], body: []}}

        other ->
          flunk("unexpected If-None-Match header: #{inspect(other)}")
      end
    end

    assert {:ok, [%Issue{id: "77", state: "status:ready"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert {:ok, [%Issue{id: "77", state: "status:ready"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, 1, nil}
    assert_receive {:request, 1, "\"etag-ready-page-1\""}
    refute_receive {:request, _, _}
  end

  test "fetch_candidate_issues_for_test replays cached paginated pages across 304 responses" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
    )

    page_one = Enum.map(1..100, &issue_payload(&1, "status:ready"))
    page_two = [issue_payload(101, "status:ready")]

    request_fun = fn :get, _url, opts ->
      params = Keyword.fetch!(opts, :params)
      page = params[:page]
      headers = Keyword.fetch!(opts, :headers)
      if_none_match = Enum.find_value(headers, &header_value(&1, "if-none-match"))

      send(self(), {:request, page, if_none_match})

      case {page, if_none_match} do
        {1, nil} -> {:ok, %{status: 200, headers: [{"etag", "\"etag-page-1\""}], body: page_one}}
        {2, nil} -> {:ok, %{status: 200, headers: [{"etag", "\"etag-page-2\""}], body: page_two}}
        {1, "\"etag-page-1\""} -> {:ok, %{status: 304, headers: [{"etag", "\"etag-page-1\""}], body: []}}
        {2, "\"etag-page-2\""} -> {:ok, %{status: 304, headers: [{"etag", "\"etag-page-2\""}], body: []}}
        other -> flunk("unexpected request shape: #{inspect(other)}")
      end
    end

    assert {:ok, initial} = Client.fetch_candidate_issues_for_test(request_fun)
    assert length(initial) == 101
    assert {:ok, replayed} = Client.fetch_candidate_issues_for_test(request_fun)
    assert Enum.map(replayed, & &1.id) == Enum.map(initial, & &1.id)

    assert_receive {:request, 1, nil}
    assert_receive {:request, 2, nil}
    assert_receive {:request, 1, "\"etag-page-1\""}
    assert_receive {:request, 2, "\"etag-page-2\""}
    refute_receive {:request, _, _}
  end

  test "fetch_candidate_issues_for_test refetches when GitHub returns 304 without cached page" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
    )

    key = {:nil_cache_304_refetch, make_ref()}

    request_fun = fn :get, _url, opts ->
      calls = Process.get(key, 0)
      Process.put(key, calls + 1)

      headers = Keyword.fetch!(opts, :headers)
      if_none_match = Enum.find_value(headers, &header_value(&1, "if-none-match"))
      send(self(), {:request, calls + 1, if_none_match})

      case calls do
        0 ->
          {:ok, %{status: 304, headers: [], body: []}}

        1 ->
          {:ok, %{status: 200, headers: [{"etag", "\"fallback-etag\""}], body: [issue_payload(88, "status:ready")]}}

        _ ->
          flunk("unexpected extra request")
      end
    end

    assert {:ok, [%Issue{id: "88", state: "status:ready"}]} =
             Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, 1, nil}
    assert_receive {:request, 2, nil}
    refute_receive {:request, _, _}
  end

  test "fetch_candidate_issues_for_test returns status and request errors for 304 fallback refetch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
    )

    status_key = {:nil_cache_304_status_error, make_ref()}

    status_failure = fn :get, _url, _opts ->
      calls = Process.get(status_key, 0)
      Process.put(status_key, calls + 1)

      if calls == 0 do
        {:ok, %{status: 304, headers: [], body: []}}
      else
        {:ok, %{status: 502, headers: [], body: %{}}}
      end
    end

    assert {:error, {:github_api_status, 502}} =
             Client.fetch_candidate_issues_for_test(status_failure)

    request_key = {:nil_cache_304_request_error, make_ref()}

    request_failure = fn :get, _url, _opts ->
      calls = Process.get(request_key, 0)
      Process.put(request_key, calls + 1)

      if calls == 0 do
        {:ok, %{status: 304, headers: [], body: []}}
      else
        {:error, :closed}
      end
    end

    assert {:error, {:github_api_request, :closed}} =
             Client.fetch_candidate_issues_for_test(request_failure)
  end

  test "fetch_candidate_issues_for_test normalizes varied etag header shapes" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo_owner: "acme",
      tracker_repo_name: "repo",
      tracker_api_token: "gh-token",
      tracker_ready_label: "status:ready",
      tracker_active_states: ["status:ready"]
    )

    key = {:etag_shape_calls, make_ref()}

    request_fun = fn :get, _url, opts ->
      call_index = Process.get(key, 0)
      Process.put(key, call_index + 1)

      headers = Keyword.fetch!(opts, :headers)
      if_none_match = Enum.find_value(headers, &header_value(&1, "if-none-match"))
      send(self(), {:request, call_index + 1, if_none_match})

      response_headers =
        case call_index do
          0 -> [:ignore_me, {"etag", "   "}]
          1 -> %{"etag" => ["\"etag-from-list\"", "\"ignored\""]}
          2 -> %{"etag" => []}
          3 -> %{"etag" => 123}
          _ -> flunk("unexpected request index #{call_index}")
        end

      {:ok, %{status: 200, headers: response_headers, body: [issue_payload(call_index + 1, "status:ready")]}}
    end

    assert {:ok, [%Issue{id: "1"}]} = Client.fetch_candidate_issues_for_test(request_fun)
    assert {:ok, [%Issue{id: "2"}]} = Client.fetch_candidate_issues_for_test(request_fun)
    assert {:ok, [%Issue{id: "3"}]} = Client.fetch_candidate_issues_for_test(request_fun)
    assert {:ok, [%Issue{id: "4"}]} = Client.fetch_candidate_issues_for_test(request_fun)

    assert_receive {:request, 1, nil}
    assert_receive {:request, 2, nil}
    assert_receive {:request, 3, "\"etag-from-list\""}
    assert_receive {:request, 4, nil}
    refute_receive {:request, _, _}
  end

  test "normalize_filter_labels_for_test returns empty list for non-list inputs" do
    assert [] == Client.normalize_filter_labels_for_test(nil)
    assert [] == Client.normalize_filter_labels_for_test("status:ready")
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

    missing_issue = fn method, _url, _opts ->
      if method == :get, do: {:ok, %{status: 404, body: %{}}}, else: flunk("patch should not run")
    end

    assert {:error, :issue_not_found} =
             Client.update_issue_state_for_test("42", "status:in-progress", missing_issue)

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
             Client.update_issue_state_for_test("bad", "status:review", success)

    invalid_transition = fn method, _url, _opts ->
      if method == :get, do: success.(:get, "", []), else: flunk("patch should not run")
    end

    assert {:error, {:invalid_github_state_transition, "status:ready", "status:review"}} =
             Client.update_issue_state_for_test("42", "status:review", invalid_transition)

    non_status_current_state = fn method, _url, _opts ->
      if method == :get do
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => 42,
             "number" => 42,
             "title" => "Issue 42",
             "body" => "Body",
             "state" => %{"unexpected" => true},
             "html_url" => "https://github.com/acme/repo/issues/42",
             "labels" => [%{"name" => "infra"}],
             "assignees" => []
           }
         }}
      else
        flunk("patch should not run")
      end
    end

    assert {:error, {:invalid_github_state_transition, nil, "status:in-progress"}} =
             Client.update_issue_state_for_test("42", "status:in-progress", non_status_current_state)
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

  defp header_value({name, value}, expected_name) do
    if String.downcase(to_string(name)) == expected_name do
      to_string(value)
    else
      nil
    end
  end

  defp header_value(_header, _expected_name), do: nil

  defp issue_payload(number, status_label) do
    %{
      "id" => number,
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.com/acme/repo/issues/#{number}",
      "labels" => [%{"name" => status_label}],
      "assignees" => []
    }
  end
end
