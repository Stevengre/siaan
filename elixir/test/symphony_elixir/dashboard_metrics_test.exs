defmodule SymphonyElixir.DashboardMetricsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dashboard.Metrics

  test "update_token_samples keeps recent samples across the graph window" do
    samples = [{0, 10}, {99_999, 20}]

    assert Metrics.update_token_samples(samples, 700_000, 30) == [{700_000, 30}]
  end

  test "prune_samples keeps only the last five seconds of samples" do
    samples = [{4_900, 1}, {5_000, 2}, {9_500, 3}, {10_000, 4}]

    assert Metrics.prune_samples(samples, 10_000) == [{5_000, 2}, {9_500, 3}, {10_000, 4}]
  end

  test "rolling_tps returns zero when there is not enough elapsed time" do
    assert Metrics.rolling_tps([{10_000, 10}], 10_000, 40) == 0.0
    assert Metrics.rolling_tps([{9_000, 40}], 10_000, 20) == 0.0
  end

  test "throttled_tps reuses the cached value within the same second" do
    assert Metrics.throttled_tps(10, 42.5, 10_999, [{9_000, 20}], 100) == {10, 42.5}
  end

  test "tps_graph renders an empty sparkline when no throughput is recorded" do
    assert Metrics.tps_graph([], 600_000, 0) == String.duplicate("▁", 24)
  end
end
