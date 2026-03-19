defmodule SymphonyElixir.StateSync.Local.Test.RoundTrip do
  @moduledoc false

  alias SymphonyElixir.StateSync.Local.Adapter
  alias SymphonyElixir.StateSync.Test.RoundTrip

  @spec assert_round_trip!() :: :ok
  def assert_round_trip! do
    RoundTrip.assert_round_trip!(
      issue_id: "local-7",
      expected_before_state: "status:ready",
      expected_after_state: "status:in-progress",
      fetch_candidate: &Adapter.fetch_candidate_issues/0,
      fetch_by_ids: &Adapter.fetch_issue_states_by_ids/1,
      update_state: &Adapter.update_issue_state/2,
      dispatch_target: &Adapter.dispatch_target_state/1
    )
  end
end
