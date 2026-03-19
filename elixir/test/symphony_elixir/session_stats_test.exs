defmodule SymphonyElixir.SessionStatsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SessionStats

  test "configured_model parses the model from codex command" do
    write_workflow_file!(RuntimeConfig.path(),
      codex_command: "codex --config foo=bar --model gpt-5.2-codex app-server"
    )

    assert SessionStats.configured_model() == "gpt-5.2-codex"
  end

  test "configured_model normalizes quoted model flags" do
    write_workflow_file!(RuntimeConfig.path(),
      codex_command: ~s(codex --config foo=bar --model "gpt-5.2-codex" app-server)
    )

    assert SessionStats.configured_model() == "gpt-5.2-codex"

    write_workflow_file!(RuntimeConfig.path(),
      codex_command: ~s(codex --model='gpt-5.3-codex' app-server)
    )

    assert SessionStats.configured_model() == "gpt-5.3-codex"
  end

  test "configured_model parses equals form and ignores blank values" do
    write_workflow_file!(RuntimeConfig.path(),
      codex_command: "codex --model=gpt-5.1-codex app-server"
    )

    assert SessionStats.configured_model() == "gpt-5.1-codex"

    write_workflow_file!(RuntimeConfig.path(),
      codex_command: ~s(codex --model "" app-server)
    )

    assert SessionStats.configured_model() == nil
  end

  test "configured_model returns nil when the codex command has no model flag" do
    write_workflow_file!(RuntimeConfig.path(), codex_command: "codex app-server")

    assert SessionStats.configured_model() == nil
  end

  test "configured_model returns nil for non-binary commands" do
    assert SessionStats.configured_model(nil) == nil
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
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

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
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "MT-1"})
    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "MT-2"})

    assert SessionStats.load_recent_history(1) == [%{"issue_identifier" => "MT-2"}]
    assert SessionStats.recent_history_limit() == 100
  end

  test "load_recent_history applies the limit after decoding valid rows" do
    workspace_root = tmp_dir!("session-stats-limit-after-decode")
    history_path = Path.join(workspace_root, ".siaan/session-stats.ndjson")

    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)
    File.mkdir_p!(Path.dirname(history_path))

    File.write!(
      history_path,
      "{\"issue_identifier\":\"MT-1\"}\n{\"issue_identifier\":\"MT-2\"}\nnot-json\n"
    )

    assert SessionStats.load_recent_history(2) == [
             %{"issue_identifier" => "MT-1"},
             %{"issue_identifier" => "MT-2"}
           ]
  end

  test "load_recent_history skips malformed ndjson lines" do
    workspace_root = tmp_dir!("session-stats-malformed")
    history_path = Path.join(workspace_root, ".siaan/session-stats.ndjson")

    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)
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
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)
    File.mkdir_p!(Path.join(workspace_root, ".siaan/session-stats.ndjson"))

    assert SessionStats.load_recent_history() == []
  end

  test "append_history_record expands workspace roots that start with tilde" do
    relative_root = "session-stats-home-#{System.unique_integer([:positive])}"
    workspace_root = Path.join("~", relative_root)
    history_path = Path.join(System.user_home() || "", "#{relative_root}/.siaan/session-stats.ndjson")

    File.rm_rf(Path.join(System.user_home() || "", relative_root))
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "GH-34"})
    assert File.exists?(history_path)
  end

  test "append_history_record expands a bare tilde workspace root" do
    home = System.user_home() || "~"
    history_path = Path.join(home, ".siaan/session-stats.ndjson")

    File.rm_rf(Path.join(home, ".siaan"))
    write_workflow_file!(RuntimeConfig.path(), workspace_root: "~")

    assert :ok = SessionStats.append_history_record(%{"issue_identifier" => "GH-35"})
    assert File.exists?(history_path)
  end

  test "append_history_record returns file-system errors without raising" do
    workspace_root = tmp_dir!("session-stats-write-error")
    blocking_path = Path.join(workspace_root, "not-a-directory")

    File.write!(blocking_path, "file")
    write_workflow_file!(RuntimeConfig.path(), workspace_root: blocking_path)

    assert {:error, _reason} = SessionStats.append_history_record(%{"issue_identifier" => "GH-36"})
  end

  test "issue sessions persist and can be replaced in the workflow workspace" do
    workspace_root = tmp_dir!("session-stats-issue-sessions")
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

    assert SessionStats.load_issue_session("issue-1") == nil

    assert :ok =
             SessionStats.save_issue_session(%{
               "issue_id" => "issue-1",
               "issue_identifier" => "GH-38",
               "issue_session_id" => "issue-session-1",
               "execution_profile" => "ready_to_in_progress"
             })

    assert SessionStats.load_issue_session("issue-1") == %{
             "issue_id" => "issue-1",
             "issue_identifier" => "GH-38",
             "issue_session_id" => "issue-session-1",
             "execution_profile" => "ready_to_in_progress"
           }

    assert :ok =
             SessionStats.save_issue_session(%{
               "issue_id" => "issue-1",
               "issue_identifier" => "GH-38",
               "issue_session_id" => "issue-session-2",
               "execution_profile" => "review_to_in_progress"
             })

    assert SessionStats.load_issue_session("issue-1")["issue_session_id"] == "issue-session-2"
  end

  test "issue-session helpers handle malformed data and deletions" do
    workspace_root = tmp_dir!("session-stats-issue-session-errors")
    issue_sessions_path = Path.join(workspace_root, ".siaan/issue-sessions.json")

    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)
    File.mkdir_p!(Path.dirname(issue_sessions_path))
    File.write!(issue_sessions_path, "not-json")

    assert SessionStats.load_issue_sessions() == %{}
    assert SessionStats.load_issue_session(:invalid) == nil
    assert {:error, :invalid_issue_session_record} = SessionStats.save_issue_session(%{})
    assert {:error, :invalid_issue_id} = SessionStats.delete_issue_session(nil)

    assert :ok =
             SessionStats.save_issue_session(%{
               "issue_id" => "issue-delete",
               "issue_identifier" => "GH-40"
             })

    assert :ok = SessionStats.delete_issue_session("issue-delete")
    assert SessionStats.load_issue_session("issue-delete") == nil
  end

  test "load_issue_sessions returns an empty map for non-file read errors" do
    workspace_root = tmp_dir!("session-stats-issue-session-read-error")
    issue_sessions_path = Path.join(workspace_root, ".siaan/issue-sessions.json")

    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)
    File.mkdir_p!(issue_sessions_path)

    assert SessionStats.load_issue_sessions() == %{}
  end

  test "pending transitions are consumed once for issue-session re-entry routing" do
    workspace_root = tmp_dir!("session-stats-pending-transition")
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

    assert :ok =
             SessionStats.mark_pending_transition(
               "issue-2",
               "GH-39",
               "review_to_in_progress"
             )

    assert SessionStats.consume_pending_transition("issue-2") == "review_to_in_progress"
    assert SessionStats.consume_pending_transition("issue-2") == nil

    assert %{
             "issue_id" => "issue-2",
             "issue_identifier" => "GH-39",
             "updated_at" => updated_at
           } = SessionStats.load_issue_session("issue-2")

    assert is_binary(updated_at)
  end

  test "pending transition helpers reuse existing issue-session records and ignore invalid ids" do
    workspace_root = tmp_dir!("session-stats-pending-transition-existing")
    write_workflow_file!(RuntimeConfig.path(), workspace_root: workspace_root)

    assert :ok =
             SessionStats.save_issue_session(%{
               "issue_id" => "issue-3",
               "issue_identifier" => "GH-42",
               "issue_session_id" => "issue-session-3"
             })

    assert :ok =
             SessionStats.mark_pending_transition(
               "issue-3",
               "GH-42",
               "review_to_in_progress"
             )

    assert SessionStats.load_issue_session("issue-3")["issue_session_id"] == "issue-session-3"
    assert SessionStats.consume_pending_transition(:invalid) == nil
  end

  test "consume_pending_transition logs and returns the transition when clearing it fails" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert SessionStats.consume_pending_transition_for_test(
                 "issue-4",
                 fn "issue-4" ->
                   %{
                     "issue_id" => "issue-4",
                     "issue_identifier" => "GH-43",
                     "pending_transition" => "review_to_in_progress"
                   }
                 end,
                 fn updated_record ->
                   send(self(), {:save_issue_session_called, updated_record})
                   {:error, :disk_full}
                 end
               ) == "review_to_in_progress"
      end)

    assert_receive {:save_issue_session_called, %{"issue_id" => "issue-4", "issue_identifier" => "GH-43"}}

    assert log =~ "Unable to clear pending transition for issue_id=issue-4: :disk_full"
  end

  test "build_running_summary and completed_record include issue-session observability fields" do
    started_at = DateTime.utc_now() |> DateTime.add(-30, :second)

    running_entry = %{
      issue_id: "issue-observability",
      identifier: "GH-41",
      session_id: "thread-1-turn-1",
      issue_session_id: "issue-session-41",
      execution_profile: "review_to_in_progress",
      execution_transition: "retry_continuation",
      session_reuse_policy: "reuse_issue_session",
      session_reuse_decision: "reused_issue_session",
      physical_session_reuse_decision: "started_new_physical_session",
      physical_session_fallback_reason: "ephemeral_app_server_lifecycle",
      codex_thread_id: "thread-1",
      physical_session_count: 2,
      issue_session_turn_count: 5,
      codex_model: "gpt-5.2-codex",
      codex_input_tokens: 20,
      codex_output_tokens: 10,
      codex_total_tokens: 30,
      started_at: started_at
    }

    summary = SessionStats.build_running_summary(running_entry)
    record = SessionStats.build_completed_record(running_entry, "completed")

    assert summary.issue_session_id == "issue-session-41"
    assert summary.execution_profile == "review_to_in_progress"
    assert summary.execution_transition == "retry_continuation"
    assert summary.session_reuse_policy == "reuse_issue_session"
    assert summary.session_reuse_decision == "reused_issue_session"
    assert summary.physical_session_reuse_decision == "started_new_physical_session"
    assert summary.physical_session_fallback_reason == "ephemeral_app_server_lifecycle"
    assert summary.physical_session_id == "thread-1"
    assert summary.physical_session_count == 2
    assert summary.issue_session_turn_count == 5

    assert record["issue_session_id"] == "issue-session-41"
    assert record["execution_profile"] == "review_to_in_progress"
    assert record["execution_transition"] == "retry_continuation"
    assert record["session_reuse_policy"] == "reuse_issue_session"
    assert record["session_reuse_decision"] == "reused_issue_session"
    assert record["physical_session_reuse_decision"] == "started_new_physical_session"
    assert record["physical_session_fallback_reason"] == "ephemeral_app_server_lifecycle"
    assert record["physical_session_id"] == "thread-1"
    assert record["physical_session_count"] == 2
    assert record["issue_session_turn_count"] == 5
  end

  test "build_running_summary includes known model pricing and version metadata" do
    workspace_root = tmp_dir!("session-stats-git-running")
    {head_sha, branch} = init_git_repo!(workspace_root)

    summary =
      SessionStats.build_running_summary(%{
        codex_input_tokens: 12,
        codex_output_tokens: 4,
        codex_model: "gpt-5.2-codex",
        siaan_version: "0.1.0",
        workspace_path: workspace_root
      })

    assert summary.siaan_version == "0.1.0"
    assert summary.model == "gpt-5.2-codex"
    assert summary.repo_head_sha == head_sha
    assert summary.repo_branch == branch
    assert summary.pricing_model == "gpt-5.2-codex"
    assert summary.pricing_source =~ "OpenAI API pricing snapshot"
    assert summary.cost_estimate_available == true
    assert summary.estimated_input_cost_usd == 0.000015
    assert summary.estimated_output_cost_usd == 0.00004
    assert summary.estimated_cost_usd == 0.000055
  end

  test "build_running_summary leaves repo metadata empty outside git workspaces" do
    workspace_root = tmp_dir!("session-stats-non-git-running")

    summary =
      SessionStats.build_running_summary(%{
        codex_input_tokens: 5,
        codex_output_tokens: 3,
        codex_model: "gpt-5.2-codex",
        workspace_path: workspace_root
      })

    assert summary.repo_head_sha == nil
    assert summary.repo_branch == nil
    assert summary.cost_estimate_available == true
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
    workspace_root = tmp_dir!("session-stats-git-completed")
    {head_sha, branch} = init_git_repo!(workspace_root)

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
          started_at: started_at,
          workspace_path: workspace_root
        },
        "completed"
      )

    assert record["issue_id"] == "issue-1"
    assert record["issue_identifier"] == "MT-1"
    assert record["session_id"] == "thread-1"
    assert record["result"] == "completed"
    assert record["model"] == "unknown-model"
    assert record["repo_head_sha"] == head_sha
    assert record["repo_branch"] == branch
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

  test "build_completed_record leaves repo metadata empty outside git workspaces" do
    record =
      SessionStats.build_completed_record(
        %{
          issue_id: "issue-2",
          identifier: "MT-2",
          session_id: "thread-2",
          codex_input_tokens: 1,
          codex_output_tokens: 2,
          codex_total_tokens: 3,
          codex_model: "gpt-5.2-codex",
          workspace_path: tmp_dir!("session-stats-non-git-completed")
        },
        "completed"
      )

    assert record["repo_head_sha"] == nil
    assert record["repo_branch"] == nil
    assert record["cost"]["cost_estimate_available"] == true
  end

  test "workspace_git_metadata returns nils when git returns blank output" do
    workspace_root = tmp_dir!("session-stats-blank-git")
    fake_bin = tmp_dir!("session-stats-fake-git-bin")
    fake_git = Path.join(fake_bin, "git")
    original_path = System.get_env("PATH") || ""

    File.write!(fake_git, "#!/bin/sh\nprintf '\\n'")
    File.chmod!(fake_git, 0o755)
    System.put_env("PATH", fake_bin)

    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert SessionStats.workspace_git_metadata(workspace_root) == %{
             repo_head_sha: nil,
             repo_branch: nil
           }
  end

  test "workspace_git_metadata returns nils when git is unavailable" do
    workspace_root = tmp_dir!("session-stats-missing-git")
    fake_bin = tmp_dir!("session-stats-missing-git-bin")
    original_path = System.get_env("PATH") || ""

    System.put_env("PATH", fake_bin)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert SessionStats.workspace_git_metadata(workspace_root) == %{
             repo_head_sha: nil,
             repo_branch: nil
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
      SymphonyElixir.TestSupport.ensure_runtime_config_store_running!()
      SymphonyElixir.TestSupport.ensure_workflow_store_running!()
      RuntimeConfig.set_path(RuntimeConfig.path())
      SymphonyElixir.RuntimeConfigStore.force_reload()
      WorkflowStore.force_reload()
    end
  end

  defp init_git_repo!(workspace_root) do
    env = [
      {"GIT_AUTHOR_NAME", "Test User"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test User"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    File.write!(Path.join(workspace_root, "README.md"), "test\n")
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace_root, env: env, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: workspace_root, env: env, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: workspace_root, env: env, stderr_to_stdout: true)
    {head_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace_root, env: env, stderr_to_stdout: true)
    {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace_root, env: env, stderr_to_stdout: true)
    {String.trim(head_sha), String.trim(branch)}
  end
end
