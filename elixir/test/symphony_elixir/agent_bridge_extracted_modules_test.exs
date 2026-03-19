defmodule SymphonyElixir.AgentBridgeExtractedModulesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBridge.Codex.{ApprovalPolicy, Session, TestSupport, Turn}
  alias SymphonyElixir.AgentBridge.Message

  test "message builder merges metadata and details with an event timestamp" do
    message =
      Message.build(
        :turn_completed,
        %{payload: %{"status" => "ok"}},
        %{worker_host: "builder-1", thread_id: "thread-123"}
      )

    assert message.event == :turn_completed
    assert message.worker_host == "builder-1"
    assert message.thread_id == "thread-123"
    assert message.payload == %{"status" => "ok"}
    assert %DateTime{} = message.timestamp
  end

  test "approval policy normalizes tool results that omit output and content items" do
    port = TestSupport.open_echo_port!()
    on_exit(fn -> TestSupport.close_port(port) end)

    payload = %{
      "id" => "tool-call-1",
      "params" => %{
        "name" => "github_graphql",
        "arguments" => %{"query" => "query Viewer { viewer { login } }"}
      }
    }

    assert :approved =
             ApprovalPolicy.handle(
               port,
               "item/tool/call",
               payload,
               Jason.encode!(payload),
               &send(self(), {:approval_message, &1}),
               %{worker_host: "builder-1"},
               fn "github_graphql", %{"query" => _query} -> %{"success" => true} end,
               false
             )

    response = TestSupport.receive_port_payload!(port)

    assert response["id"] == "tool-call-1"
    assert response["result"]["success"] == true
    assert is_binary(response["result"]["output"])

    assert response["result"]["contentItems"] == [
             %{"type" => "inputText", "text" => response["result"]["output"]}
           ]

    assert_received {:approval_message, %{event: :tool_call_completed, payload: ^payload}}
  end

  test "approval policy auto-answers request-user-input prompts in unattended mode" do
    port = TestSupport.open_echo_port!()
    on_exit(fn -> TestSupport.close_port(port) end)

    payload = %{
      "id" => "user-input-1",
      "params" => %{
        "questions" => [
          %{"id" => "policy", "prompt" => "Need approval?", "options" => [%{"label" => "Approve Once"}]}
        ]
      }
    }

    assert :approved =
             ApprovalPolicy.handle(
               port,
               "item/tool/requestUserInput",
               payload,
               Jason.encode!(payload),
               &send(self(), {:approval_message, &1}),
               %{worker_host: "builder-1"},
               fn _, _ -> flunk("tool executor should not be called for request-user-input") end,
               false
             )

    response = TestSupport.receive_port_payload!(port)

    assert response == %{
             "id" => "user-input-1",
             "result" => %{
               "answers" => %{
                 "policy" => %{
                   "answers" => ["This is a non-interactive session. Operator input is unavailable."]
                 }
               }
             }
           }

    assert_received {:approval_message,
                     %{
                       event: :tool_input_auto_answered,
                       answer: "This is a non-interactive session. Operator input is unavailable."
                     }}
  end

  test "session buffers partial idle transport lines and logs completed notifications" do
    port = TestSupport.open_echo_port!()
    on_exit(fn -> TestSupport.close_port(port) end)

    issue = %Issue{
      id: "issue-session-idle",
      identifier: "MT-AB-1",
      title: "Idle notifications",
      description: "Exercise idle transport logging",
      state: "In Progress",
      url: "https://example.org/issues/MT-AB-1",
      labels: []
    }

    session = TestSupport.session_for_port(port)

    assert {:handled, buffered_session} =
             Session.handle_transport_message(
               session,
               {port, {:data, {:noeol, ~s({"method":"thread/started")}}},
               issue
             )

    assert buffered_session.state.port_pending_line == ~s({"method":"thread/started")

    log =
      capture_log([level: :debug], fn ->
        assert {:handled, flushed_session} =
                 Session.handle_transport_message(
                   buffered_session,
                   {port, {:data, {:eol, "}"}}},
                   issue
                 )

        assert flushed_session.state.port_pending_line == ""
      end)

    assert log =~ "Ignoring idle app-server notification for issue_id=issue-session-idle issue_identifier=MT-AB-1: thread/started"
  end

  test "session surfaces idle port exits with the updated session state" do
    port = TestSupport.open_echo_port!()
    on_exit(fn -> TestSupport.close_port(port) end)

    issue = %Issue{
      id: "issue-session-exit",
      identifier: "MT-AB-2",
      title: "Idle exits",
      description: "Exercise idle port exit handling",
      state: "In Progress",
      url: "https://example.org/issues/MT-AB-2",
      labels: []
    }

    session = TestSupport.session_for_port(port, %{state: %{port_pending_line: "partial"}})

    assert {:stop, {:app_server_exit, 9}, updated_session} =
             Session.handle_transport_message(session, {port, {:exit_status, 9}}, issue)

    assert updated_session.state.port_pending_line == ""
  end

  test "turn returns turn_failed payloads from the extracted codex bridge" do
    %{workspace: workspace, codex_binary: codex_binary, test_root: test_root} =
      write_fake_codex_fixture!("agent-bridge-turn-failed", """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-failed"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-failed"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/failed","params":{"message":"boom"}}'
            exit 0
            ;;
        esac
      done
      """)

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "issue-turn-failed",
      identifier: "MT-AB-3",
      title: "Turn failed",
      description: "Exercise turn failure handling",
      state: "In Progress",
      url: "https://example.org/issues/MT-AB-3",
      labels: []
    }

    assert {:ok, session} =
             Session.start_session(workspace, codex_command: "#{codex_binary} app-server")

    try do
      assert {:error, {:turn_failed, %{"message" => "boom"}}} =
               Turn.run_turn(session, "Trigger a failure", issue)
    after
      assert :ok = Session.stop_session(session)
    end
  end

  test "turn times out when the extracted codex bridge stops streaming after startup" do
    %{workspace: workspace, codex_binary: codex_binary, test_root: test_root} =
      write_fake_codex_fixture!(
        "agent-bridge-turn-timeout",
        """
        #!/bin/sh
        count=0

        while IFS= read -r _line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
              ;;
            4)
              sleep 1
              exit 0
              ;;
          esac
        done
        """,
        codex_turn_timeout_ms: 25
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "issue-turn-timeout",
      identifier: "MT-AB-4",
      title: "Turn timeout",
      description: "Exercise turn timeout handling",
      state: "In Progress",
      url: "https://example.org/issues/MT-AB-4",
      labels: []
    }

    assert {:ok, session} =
             Session.start_session(workspace, codex_command: "#{codex_binary} app-server")

    try do
      assert {:error, :turn_timeout} = Turn.run_turn(session, "Wait forever", issue)
    after
      assert :ok = Session.stop_session(session)
    end
  end

  defp write_fake_codex_fixture!(prefix, script, workflow_overrides \\ []) do
    test_root = tmp_dir!(prefix)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-AB")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace)
    File.write!(codex_binary, script)
    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        ],
        workflow_overrides
      )
    )

    %{test_root: test_root, workspace: workspace, codex_binary: codex_binary}
  end
end
