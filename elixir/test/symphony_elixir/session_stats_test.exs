defmodule SymphonyElixir.SessionStatsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SessionStats

  test "configured_model parses the model from codex command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config foo=bar --model gpt-5.2-codex app-server"
    )

    assert SessionStats.configured_model() == "gpt-5.2-codex"
  end

  test "configured_model returns nil when the codex command has no model flag" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")

    assert SessionStats.configured_model() == nil
  end

  test "estimate_cost returns API billing estimate for priced models" do
    estimate = SessionStats.estimate_cost("gpt-5.2-codex", 1_000_000, 500_000)

    assert estimate.cost_estimate_available == true
    assert estimate.pricing_model == "gpt-5.2-codex"
    assert estimate.estimated_input_cost_usd == 1.25
    assert estimate.estimated_output_cost_usd == 5.0
    assert estimate.estimated_cost_usd == 6.25
  end

  test "estimate_cost returns API billing estimate for gpt-5.3-codex" do
    estimate = SessionStats.estimate_cost("gpt-5.3-codex", 1_000_000, 500_000)

    assert estimate.cost_estimate_available == true
    assert estimate.pricing_model == "gpt-5.3-codex"
    assert estimate.estimated_input_cost_usd == 1.75
    assert estimate.estimated_output_cost_usd == 7.0
    assert estimate.estimated_cost_usd == 8.75
  end

  test "estimate_cost leaves unknown models unpriced" do
    estimate = SessionStats.estimate_cost("unknown-model", 123, 456)

    assert estimate.cost_estimate_available == false
    assert estimate.estimated_cost_usd == nil
    assert estimate.pricing_source == nil
  end

  test "estimate_cost leaves nil models unpriced" do
    estimate = SessionStats.estimate_cost(nil, 123, 456)

    assert estimate.cost_estimate_available == false
    assert estimate.pricing_model == nil
    assert estimate.estimated_cost_usd == nil
  end

  test "recent history starts empty and appends records under the workflow workspace" do
    workspace_root = tmp_dir!("session-stats-history")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert SessionStats.load_recent_history() == []

    assert :ok =
             SessionStats.append_history_record(%{
               "issue_identifier" => "MT-1",
               "result" => "completed"
             })

    assert SessionStats.load_recent_history() == [
             %{"issue_identifier" => "MT-1", "result" => "completed"}
           ]
  end

  test "load_recent_history respects the requested limit" do
    workspace_root = tmp_dir!("session-stats-limit")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "MT-1"})
    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "MT-2"})

    assert SessionStats.load_recent_history(1) == [%{"issue_identifier" => "MT-2"}]
    assert SessionStats.recent_history_limit() == 100
  end

  test "load_recent_history skips malformed ndjson lines" do
    workspace_root = tmp_dir!("session-stats-malformed")
    history_path = Path.join(workspace_root, ".siaan/session-stats.ndjson")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(Path.dirname(history_path))

    File.write!(
      history_path,
      "{\"issue_identifier\":\"MT-1\"}\nnot-json\n{\"issue_identifier\":\"MT-2\"}\n"
    )

    assert SessionStats.load_recent_history() == [
             %{"issue_identifier" => "MT-1"},
             %{"issue_identifier" => "MT-2"}
           ]
  end

  test "load_recent_history returns an empty list for non-file read errors" do
    workspace_root = tmp_dir!("session-stats-read-error")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.mkdir_p!(Path.join(workspace_root, ".siaan/session-stats.ndjson"))

    assert SessionStats.load_recent_history() == []
  end

  test "append_history_record expands workspace roots that start with tilde" do
    relative_root = "session-stats-home-#{System.unique_integer([:positive])}"
    workspace_root = Path.join("~", relative_root)
    history_path = Path.join(System.user_home() || "", "#{relative_root}/.siaan/session-stats.ndjson")

    File.rm_rf(Path.join(System.user_home() || "", relative_root))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "GH-34"})
    assert File.exists?(history_path)
  end

  test "append_history_record expands a bare tilde workspace root" do
    home = System.user_home() || "~"
    history_path = Path.join(home, ".siaan/session-stats.ndjson")

    File.rm_rf(Path.join(home, ".siaan"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "~")

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "GH-35"})
    assert File.exists?(history_path)
  end

  test "append_history_record returns file-system errors without raising" do
    workspace_root = tmp_dir!("session-stats-write-error")
    blocking_path = Path.join(workspace_root, "not-a-directory")

    File.write!(blocking_path, "file")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: blocking_path)

    assert {:error, _reason} = SessionStats.append_history_record(%{"issue_identifier" => "GH-36"})
  end

  test "build_running_summary includes known model pricing and version metadata" do
    summary =
      SessionStats.build_running_summary(%{
        codex_input_tokens: 12,
        codex_output_tokens: 4,
        codex_model: "gpt-5.2-codex",
        siaan_version: "0.1.0"
      })

    assert summary.siaan_version == "0.1.0"
    assert summary.model == "gpt-5.2-codex"
    assert summary.pricing_model == "gpt-5.2-codex"
    assert summary.pricing_source =~ "OpenAI API pricing snapshot"
    assert summary.cost_estimate_available == true
    assert summary.estimated_input_cost_usd == 0.000015
    assert summary.estimated_output_cost_usd == 0.00004
    assert summary.estimated_cost_usd == 0.000055
  end

  test "build_running_summary falls back to app version and unknown pricing when model is absent" do
    summary = SessionStats.build_running_summary(%{})

    assert summary.siaan_version == "0.1.0"
    assert summary.model == nil
    assert summary.pricing_model == nil
    assert summary.pricing_source == nil
    assert summary.cost_estimate_available == false
    assert summary.estimated_cost_usd == nil
  end

  test "build_completed_record captures timing, tokens, and unknown-model fallback" do
    started_at = DateTime.utc_now() |> DateTime.add(-12, :second) |> DateTime.truncate(:second)

    record =
      SessionStats.build_completed_record(
        %{
          issue_id: "issue-1",
          identifier: "MT-1",
          session_id: "thread-1",
          codex_input_tokens: 3,
          codex_output_tokens: 4,
          codex_total_tokens: 7,
          codex_model: "unknown-model",
          turn_count: 2,
          started_at: started_at
        },
        "completed"
      )

    assert record["issue_id"] == "issue-1"
    assert record["issue_identifier"] == "MT-1"
    assert record["session_id"] == "thread-1"
    assert record["result"] == "completed"
    assert record["model"] == "unknown-model"
    assert record["turn_count"] == 2
    assert record["started_at"] == DateTime.to_iso8601(started_at)
    assert record["completed_at"] != nil
    assert record["runtime_seconds"] >= 12

    assert record["tokens"] == %{
             "input_tokens" => 3,
             "output_tokens" => 4,
             "total_tokens" => 7
           }

    assert record["cost"] == %{
             "estimated_cost_usd" => nil,
             "estimated_input_cost_usd" => nil,
             "estimated_output_cost_usd" => nil,
             "cost_estimate_available" => false
           }
  end

  test "build_completed_record falls back to app version and zero runtime without started_at" do
    record = SessionStats.build_completed_record(%{identifier: "MT-2"}, "terminated")

    assert record["issue_identifier"] == "MT-2"
    assert record["siaan_version"] == "0.1.0"
    assert record["started_at"] == nil
    assert record["runtime_seconds"] == 0

    assert record["tokens"] == %{
             "input_tokens" => 0,
             "output_tokens" => 0,
             "total_tokens" => 0
           }
  end

  test "build_completed_record includes pricing metadata for known models" do
    record =
      SessionStats.build_completed_record(
        %{
          identifier: "MT-3",
          codex_input_tokens: 12,
          codex_output_tokens: 4,
          codex_total_tokens: 16,
          codex_model: "gpt-5.2-codex"
        },
        "completed"
      )

    assert record["model"] == "gpt-5.2-codex"
    assert record["pricing_model"] == "gpt-5.2-codex"
    assert record["pricing_source"] =~ "OpenAI API pricing snapshot"

    assert record["cost"] == %{
             "estimated_cost_usd" => 0.000055,
             "estimated_input_cost_usd" => 0.000015,
             "estimated_output_cost_usd" => 0.00004,
             "cost_estimate_available" => true
           }
  end

  test "app_version returns unknown when the application metadata is unavailable" do
    :ok = Application.stop(:symphony_elixir)
    :ok = Application.unload(:symphony_elixir)

    try do
      assert SessionStats.app_version() == "unknown"
    after
      :ok = Application.load(:symphony_elixir)
      SymphonyElixir.TestSupport.ensure_test_application_started!()
      SymphonyElixir.TestSupport.ensure_workflow_store_running!()
      Workflow.set_workflow_file_path(Workflow.workflow_file_path())
      WorkflowStore.force_reload()
    end
  end
end
