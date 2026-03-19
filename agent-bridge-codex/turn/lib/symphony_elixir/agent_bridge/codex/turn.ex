defmodule SymphonyElixir.AgentBridge.Codex.Turn do
  @moduledoc false

  require Logger

  alias SymphonyElixir.AgentBridge.Session, as: BridgeSession
  alias SymphonyElixir.AgentBridge.Codex.{ApprovalPolicy, Session}
  alias SymphonyElixir.Config

  @turn_start_id 3

  @spec run_turn(BridgeSession.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %BridgeSession{
          native: %{
            port: port,
            approval_policy: approval_policy,
            auto_approve_requests: auto_approve_requests,
            turn_sandbox_policy: turn_sandbox_policy,
            tracker_kind: tracker_kind,
            thread_sandbox: thread_sandbox
          },
          metadata: metadata,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &Session.default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        SymphonyElixir.AgentBridge.Codex.DynamicTool.execute(tool, arguments, tracker_kind: tracker_kind)
      end)

    turn_context = %{
      issue: issue,
      workspace: workspace,
      approval_policy: approval_policy,
      thread_sandbox: thread_sandbox,
      turn_sandbox_policy: turn_sandbox_policy
    }

    case start_turn_for_session(session, prompt, turn_context) do
      {:ok, updated_session, turn_id} ->
        session_id = "#{updated_session.thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        Session.emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: updated_session.thread_id,
            turn_id: turn_id,
            physical_session_reuse_decision: updated_session.physical_session_reuse_decision,
            physical_session_fallback_reason: updated_session.physical_session_fallback_reason
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               app_session: updated_session,
               result: result,
               session_id: session_id,
               thread_id: updated_session.thread_id,
               turn_id: turn_id,
               physical_session_reuse_decision: updated_session.physical_session_reuse_decision,
               physical_session_fallback_reason: updated_session.physical_session_fallback_reason
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            Session.emit_message(
              on_message,
              :turn_ended_with_error,
              %{session_id: session_id, reason: reason},
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        Session.emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         request_id \\ @turn_start_id
       ) do
    Session.send_message(port, %{
      "method" => "turn/start",
      "id" => request_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => prompt}],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case Session.await_response(port, request_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp start_turn_for_session(%BridgeSession{native: %{port: port}, thread_id: thread_id} = session, prompt, context) do
    case start_turn(
           port,
           thread_id,
           prompt,
           context.issue,
           context.workspace,
           context.approval_policy,
           context.turn_sandbox_policy
         ) do
      {:ok, turn_id} -> {:ok, session, turn_id}
      {:error, _reason} = error -> error
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_incoming(
          port,
          on_message,
          pending_line <> to_string(chunk),
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(on_message, :turn_failed, payload, payload_string, port, Map.get(payload, "params"))
        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(on_message, :turn_cancelled, payload, payload_string, port, Map.get(payload, "params"))
        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        Session.emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: payload_string},
          Session.metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        Session.log_non_json_stream_line(payload_string, "turn stream")

        Session.emit_message(
          on_message,
          :malformed,
          %{payload: payload_string, raw: payload_string},
          Session.metadata_from_message(port, %{raw: payload_string})
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    Session.emit_message(
      on_message,
      event,
      %{payload: payload, raw: payload_string, details: payload_details},
      Session.metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = Session.metadata_from_message(port, payload)

    case ApprovalPolicy.handle(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        Session.emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        Session.emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          Session.emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          Session.emit_message(
            on_message,
            :notification,
            %{payload: payload, raw: payload_string},
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp needs_input?(method, payload) when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
