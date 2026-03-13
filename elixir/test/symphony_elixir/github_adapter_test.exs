defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter
  alias SymphonyElixir.GitHub.Issue, as: GitHubIssue

  defmodule FakeGitHubClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [sample_issue(7, "status:ready")]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, [sample_issue(5, "status:review")]}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetch_issue_states_by_ids_called, ids})
      {:ok, Enum.map(ids, &sample_issue(String.to_integer(&1), "status:in-progress"))}
    end

    def create_comment(issue_id, body) do
      send(self(), {:create_comment_called, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state_called, issue_id, state_name})

      case state_name do
        "status:review" -> :ok
        "broken" -> {:error, :boom}
      end
    end

    defp sample_issue(number, status_label) do
      %GitHubIssue{
        id: Integer.to_string(number),
        number: number,
        title: "Issue #{number}",
        body: "Body #{number}",
        state: status_label,
        url: "https://github.com/acme/repo/issues/#{number}",
        labels: [status_label, "infra"],
        assignees: ["octocat"]
      }
    end
  end

  setup do
    previous_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_module)
      end
    end)

    :ok
  end

  test "adapter delegates reads and writes through GitHub client" do
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
    assert issue.id == "7"
    assert issue.identifier == "GH-7"
    assert issue.state == "status:ready"
    assert issue.description == "Body 7"
    assert_receive :fetch_candidate_issues_called

    assert {:ok, [review_issue]} = Adapter.fetch_issues_by_states(["status:review"])
    assert review_issue.id == "5"
    assert review_issue.state == "status:review"
    assert_receive {:fetch_issues_by_states_called, ["status:review"]}

    assert {:ok, [refreshed_issue]} = Adapter.fetch_issue_states_by_ids(["5"])
    assert refreshed_issue.id == "5"
    assert refreshed_issue.state == "status:in-progress"
    assert_receive {:fetch_issue_states_by_ids_called, ["5"]}

    assert :ok = Adapter.create_comment("5", "looks good")
    assert_receive {:create_comment_called, "5", "looks good"}

    assert :ok = Adapter.update_issue_state("5", "status:review")
    assert_receive {:update_issue_state_called, "5", "status:review"}

    assert {:error, :boom} = Adapter.update_issue_state("5", "broken")
    assert_receive {:update_issue_state_called, "5", "broken"}
  end

  test "tracker selects github adapter when tracker kind is github" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: "acme/repo",
      tracker_api_token: "gh-token"
    )

    assert SymphonyElixir.Tracker.adapter() == SymphonyElixir.GitHub.Adapter
  end
end
