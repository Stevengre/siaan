defmodule SymphonyElixir.AgentBridge.Codex.TestSupport do
  @moduledoc false

  alias SymphonyElixir.AgentBridge.Session

  @spec open_echo_port!() :: port()
  def open_echo_port! do
    Port.open({:spawn, ~c"cat"}, [:binary, :exit_status, line: 1_024])
  end

  @spec receive_port_payload!(port(), timeout()) :: map()
  def receive_port_payload!(port, timeout \\ 1_000) when is_port(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        line
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      {^port, {:data, line}} ->
        line
        |> IO.iodata_to_binary()
        |> Jason.decode!()
    after
      timeout ->
        raise "expected port payload for #{inspect(port)}"
    end
  end

  @spec close_port(port()) :: :ok
  def close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  @spec session_for_port(port(), map()) :: Session.t()
  def session_for_port(port, attrs \\ %{}) when is_port(port) and is_map(attrs) do
    base_attrs = %{
      native: %{port: port},
      metadata: %{codex_app_server_pid: "echo-port"},
      state: %{port_pending_line: ""}
    }

    Session.new(SymphonyElixir.AgentBridge.Codex, Map.merge(base_attrs, attrs))
  end
end
