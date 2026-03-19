defmodule SymphonyElixir.AgentBridge.TestBridge do
  @moduledoc """
  Minimal in-memory bridge used to exercise the interface contract.
  """

  @behaviour SymphonyElixir.AgentBridge

  alias SymphonyElixir.AgentBridge.Session

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
  def start_session(workspace, _opts \\ []) do
    {:ok,
     Session.new(__MODULE__, %{
       native: %{turn_count: 0},
       workspace: workspace,
       thread_id: "mock-thread",
       physical_session_reuse_decision: "started_new_physical_session",
       physical_session_fallback_reason: nil
     })}
  end

  @impl true
  def run_turn(%Session{} = session, _prompt, _issue, _opts \\ []) do
    turn_count = get_in(session.native, [:turn_count]) || 0
    updated_session = %{session | native: %{turn_count: turn_count + 1}}
    turn_id = "mock-turn-#{turn_count + 1}"

    {:ok,
     %{
       app_session: updated_session,
       result: :ok,
       session_id: "#{updated_session.thread_id}-#{turn_id}",
       thread_id: updated_session.thread_id,
       turn_id: turn_id,
       physical_session_reuse_decision: updated_session.physical_session_reuse_decision,
       physical_session_fallback_reason: updated_session.physical_session_fallback_reason
     }}
  end

  @impl true
  def stop_session(_session), do: :ok

  @impl true
  def mark_physical_session_reuse(%Session{} = session) do
    %{
      session
      | physical_session_reuse_decision: "reused_physical_session",
        physical_session_fallback_reason: nil
    }
  end

  @impl true
  def handle_transport_message(_session, _message, _issue), do: :unhandled
end
