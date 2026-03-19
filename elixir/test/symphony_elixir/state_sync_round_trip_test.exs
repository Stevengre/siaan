defmodule SymphonyElixir.StateSyncRoundTripTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StateSync.GitHub.Test.RoundTrip, as: GitHubRoundTrip
  alias SymphonyElixir.StateSync.Local.Test.RoundTrip, as: LocalRoundTrip

  test "state-sync round-trip contract covers the github implementation" do
    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_repo_owner: "acme",
      state_repo_name: "repo",
      state_api_token: "gh-token",
      state_ready_label: "status:ready",
      state_active_states: ["status:ready", "status:in-progress"]
    )

    Application.put_env(:symphony_elixir, :github_client_module, GitHubRoundTrip.Client)
    {:ok, _pid} = GitHubRoundTrip.Client.start_link("status:ready")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      GitHubRoundTrip.Client.stop()
    end)

    assert :ok = GitHubRoundTrip.assert_round_trip!()
  end

  test "github round-trip client supports compatibility fetches and idempotent shutdown" do
    {:ok, _pid} = GitHubRoundTrip.Client.start_link("status:ready")

    assert {:ok, [issue]} = GitHubRoundTrip.Client.fetch_issues_by_states(["status:ready"])
    assert issue.id == "github-7"
    assert issue.state == "status:ready"

    assert :ok = GitHubRoundTrip.Client.stop()
    assert :ok = GitHubRoundTrip.Client.stop()
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

    assert :ok = LocalRoundTrip.assert_round_trip!()
  end
end
