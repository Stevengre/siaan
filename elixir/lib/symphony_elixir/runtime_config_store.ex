defmodule SymphonyElixir.RuntimeConfigStore do
  @moduledoc """
  Caches the last known good runtime payload at the configured runtime config path.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.RuntimeConfig

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec current(GenServer.server()) :: {:ok, RuntimeConfig.loaded_runtime()} | {:error, term()}
  def current(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(server, :current)

      _ ->
        RuntimeConfig.load()
    end
  end

  @spec force_reload(GenServer.server()) :: :ok | {:error, term()}
  def force_reload(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(server, :force_reload)

      _ ->
        case RuntimeConfig.load() do
          {:ok, _runtime} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    case load_state(RuntimeConfig.path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = RuntimeConfig.path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, runtime} <- RuntimeConfig.load(path),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: runtime}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload runtime config path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
