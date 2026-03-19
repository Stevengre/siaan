defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Compatibility wrapper for the extracted Codex bridge implementation.
  """

  alias SymphonyElixir.AgentBridge.Codex
  alias SymphonyElixir.AgentBridge.Session

  @type session :: Session.t()

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run(workspace, prompt, issue, opts \\ []), to: Codex

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  defdelegate start_session(workspace, opts \\ []), to: Codex

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate run_turn(session, prompt, issue, opts \\ []), to: Codex

  @spec stop_session(session()) :: :ok
  defdelegate stop_session(session), to: Codex

  @spec mark_physical_session_reuse(session()) :: session()
  defdelegate mark_physical_session_reuse(session), to: Codex
end
