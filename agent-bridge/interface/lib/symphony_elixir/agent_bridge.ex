defmodule SymphonyElixir.AgentBridge do
  @moduledoc """
  Behaviour for orchestrator-facing agent bridge implementations.
  """

  alias SymphonyElixir.AgentBridge.Session

  @type session :: Session.t()
  @type turn_result :: {:ok, map()} | {:error, term()}
  @type transport_result :: {:handled, session()} | {:stop, term(), session()} | :unhandled

  @callback run(Path.t(), String.t(), map(), keyword()) :: turn_result()
  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: turn_result()
  @callback stop_session(session()) :: :ok
  @callback mark_physical_session_reuse(session()) :: session()
  @callback handle_transport_message(session(), term(), map()) :: transport_result()
end
