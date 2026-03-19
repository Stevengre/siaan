defmodule SymphonyElixir.AgentBridge.Codex do
  @moduledoc """
  Codex implementation of the generic agent bridge behaviour.
  """

  @behaviour SymphonyElixir.AgentBridge

  alias SymphonyElixir.AgentBridge.Session, as: BridgeSession

  @impl true
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @impl true
  def start_session(workspace, opts \\ []) do
    SymphonyElixir.AgentBridge.Codex.Session.start_session(workspace, opts)
  end

  @impl true
  def run_turn(%BridgeSession{} = session, prompt, issue, opts \\ []) do
    SymphonyElixir.AgentBridge.Codex.Turn.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(%BridgeSession{} = session) do
    SymphonyElixir.AgentBridge.Codex.Session.stop_session(session)
  end

  @impl true
  def mark_physical_session_reuse(%BridgeSession{} = session) do
    SymphonyElixir.AgentBridge.Codex.Session.mark_physical_session_reuse(session)
  end

  @impl true
  def handle_transport_message(%BridgeSession{} = session, message, issue) do
    SymphonyElixir.AgentBridge.Codex.Session.handle_transport_message(session, message, issue)
  end
end
