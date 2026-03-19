defmodule SymphonyElixir.StateSync.Test.RoundTrip do
  @moduledoc false

  import ExUnit.Assertions

  alias SymphonyElixir.StateSync.Issue

  @spec assert_round_trip!(keyword()) :: :ok
  def assert_round_trip!(opts) do
    issue_id = Keyword.fetch!(opts, :issue_id)
    expected_before = Keyword.fetch!(opts, :expected_before_state)
    expected_after = Keyword.fetch!(opts, :expected_after_state)
    fetch_candidate = Keyword.fetch!(opts, :fetch_candidate)
    fetch_by_ids = Keyword.fetch!(opts, :fetch_by_ids)
    update_state = Keyword.fetch!(opts, :update_state)
    create_comment = Keyword.get(opts, :create_comment, fn _issue_id, _body -> :ok end)
    dispatch_target = Keyword.fetch!(opts, :dispatch_target)

    assert {:ok, [%Issue{} = candidate | _]} = fetch_candidate.()
    assert candidate.id == issue_id
    assert candidate.state == expected_before
    assert dispatch_target.(candidate) == expected_after

    assert :ok = create_comment.(issue_id, "round-trip validation")
    assert :ok = update_state.(issue_id, expected_after)

    assert {:ok, [%Issue{} = refreshed | _]} = fetch_by_ids.([issue_id])
    assert refreshed.id == issue_id
    assert refreshed.state == expected_after
    :ok
  end
end
