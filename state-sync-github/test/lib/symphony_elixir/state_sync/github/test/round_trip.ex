defmodule SymphonyElixir.StateSync.GitHub.Test.RoundTrip do
  @moduledoc false

  alias SymphonyElixir.StateSync.GitHub.Adapter
  alias SymphonyElixir.StateSync.GitHub.Issue, as: GitHubIssue
  alias SymphonyElixir.StateSync.Test.RoundTrip

  defmodule Client do
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

  @spec assert_round_trip!() :: :ok
  def assert_round_trip! do
    RoundTrip.assert_round_trip!(
      issue_id: "github-7",
      expected_before_state: "status:ready",
      expected_after_state: "status:in-progress",
      fetch_candidate: &Adapter.fetch_candidate_issues/0,
      fetch_by_ids: &Adapter.fetch_issue_states_by_ids/1,
      update_state: &Adapter.update_issue_state/2,
      create_comment: &Adapter.create_comment/2,
      dispatch_target: &Adapter.dispatch_target_state/1
    )
  end
end
