defmodule SymphonyElixir.AgentBridge.ContractCase do
  @moduledoc """
  Shared ExUnit bridge contract tests.
  """

  alias SymphonyElixir.AgentBridge.Session

  defmacro define_basic_contract_tests(opts) do
    bridge = Keyword.fetch!(opts, :bridge)
    context_builder = Keyword.fetch!(opts, :context_builder)
    bridge_label = Macro.to_string(bridge)
    basic_name = "#{bridge_label} satisfies the basic bridge session contract"
    reuse_name = "#{bridge_label} marks physical session reuse consistently"

    quote do
      test unquote(basic_name) do
        bridge = unquote(bridge)
        context_builder = unquote(context_builder)
        %{workspace: workspace, issue: issue, opts: opts} = context_builder.()

        assert {:ok, %Session{bridge: ^bridge} = session} = bridge.start_session(workspace, opts)
        assert {:ok, result} = bridge.run_turn(session, "Bridge contract prompt", issue)
        assert %Session{bridge: ^bridge} = result.app_session
        assert is_binary(result.thread_id)
        assert is_binary(result.turn_id)
        assert :ok = bridge.stop_session(result.app_session)
      end

      test unquote(reuse_name) do
        bridge = unquote(bridge)
        context_builder = unquote(context_builder)
        %{workspace: workspace, opts: opts} = context_builder.()

        assert {:ok, %Session{bridge: ^bridge} = session} = bridge.start_session(workspace, opts)

        reused_session = bridge.mark_physical_session_reuse(session)

        assert reused_session.physical_session_reuse_decision == "reused_physical_session"
        assert reused_session.physical_session_fallback_reason == nil
        assert :ok = bridge.stop_session(reused_session)
      end
    end
  end
end
