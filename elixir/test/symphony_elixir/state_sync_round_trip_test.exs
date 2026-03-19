defmodule SymphonyElixir.StateSyncRoundTripTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StateSync.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.StateSync.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.StateSync.Local.Adapter, as: LocalAdapter
  alias SymphonyElixir.StateSync.Test.RoundTrip

  defmodule GitHubRoundTripClient do
    alias SymphonyElixir.StateSync.GitHub.Issue, as: GitHubIssue

    def start_link(initial_state) do
      Agent.start_link(fn -> %{issue: initial_issue(initial_state), comments: []} end, name: __MODULE__)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _pid -> Agent.stop(__MODULE__)
      end
    end

    def fetch_candidate_issues do
      {:ok, [Agent.get(__MODULE__, & &1.issue)]}
    end

    def fetch_issues_by_states(_states), do: fetch_candidate_issues()

    def fetch_issue_states_by_ids(_issue_ids), do: fetch_candidate_issues()

    def create_comment(issue_id, body) do
      Agent.update(__MODULE__, fn state ->
        %{state | comments: [{issue_id, body} | state.comments]}
      end)

      :ok
    end

    def update_issue_state(_issue_id, state_name) do
      Agent.update(__MODULE__, fn state ->
        %{state | issue: %{state.issue | state: state_name}}
      end)

      :ok
    end

    defp initial_issue(state_name) do
      %GitHubIssue{
        id: "github-7",
        number: 7,
        title: "Round trip",
        body: "GitHub contract test",
        state: state_name,
        url: "https://github.com/acme/repo/issues/7",
        labels: ["status:ready"],
        assignees: ["octocat"]
      }
    end
  end

  test "state-sync round-trip contract covers the github implementation" do
    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_repo_owner: "acme",
      state_repo_name: "repo",
      state_api_token: "gh-token",
      state_ready_label: "status:ready",
      state_active_states: ["status:ready", "status:in-progress"]
    )

    Application.put_env(:symphony_elixir, :github_client_module, GitHubRoundTripClient)
    {:ok, _pid} = GitHubRoundTripClient.start_link("status:ready")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      GitHubRoundTripClient.stop()
    end)

    assert :ok =
             RoundTrip.assert_round_trip!(
               issue_id: "github-7",
               expected_before_state: "status:ready",
               expected_after_state: "status:in-progress",
               fetch_candidate: &GitHubAdapter.fetch_candidate_issues/0,
               fetch_by_ids: &GitHubAdapter.fetch_issue_states_by_ids/1,
               update_state: &GitHubAdapter.update_issue_state/2,
               create_comment: &GitHubAdapter.create_comment/2,
               dispatch_target: &GitHubAdapter.dispatch_target_state/1
             )
  end

  test "state-sync round-trip contract covers the local implementation" do
    root = tmp_dir!("state-sync-local-round-trip")
    config_path = Path.join(root, "config.toml")
    workflow_path = Path.join(root, "workflow.yaml")
    ready_dir = Path.join(root, "ready")

    File.mkdir_p!(ready_dir)

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{Path.expand("..", File.cwd!())}"
      workflow = "#{workflow_path}"
      runtime = "local"

      [projects.siaan.state]
      type = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
      review:
        activities: []
        transitions: []
      """
    )

    File.write!(
      Path.join(ready_dir, "local-7.md"),
      """
      ---
      identifier: LOCAL-7
      title: Local round trip
      ---
      Local contract test
      """
    )

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "local",
      state_local_config_path: config_path,
      state_local_project: "siaan",
      state_active_states: ["status:ready", "status:in-progress"],
      state_terminal_states: ["status:done"]
    )

    assert :ok =
             RoundTrip.assert_round_trip!(
               issue_id: "local-7",
               expected_before_state: "status:ready",
               expected_after_state: "status:in-progress",
               fetch_candidate: &LocalAdapter.fetch_candidate_issues/0,
               fetch_by_ids: &LocalAdapter.fetch_issue_states_by_ids/1,
               update_state: &LocalAdapter.update_issue_state/2,
               dispatch_target: &LocalAdapter.dispatch_target_state/1
             )
  end
end
