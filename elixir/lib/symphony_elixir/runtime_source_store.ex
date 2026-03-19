defmodule SymphonyElixir.RuntimeSourceStore do
  @moduledoc """
  Caches the last known good runtime source payload and reloads it periodically.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{RuntimeConfig, RuntimeSource}

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:module, :runtime, :error, :path, :stamp]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, RuntimeSource.loaded_runtime()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        RuntimeSource.module().current()
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case RuntimeSource.module().current() do
          {:ok, _runtime} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    case load_state(RuntimeSource.module()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case maybe_reload_current_state(state) do
      {:ok, %State{runtime: runtime} = new_state} ->
        {:reply, {:ok, runtime}, new_state}

      {:error, reason, %State{runtime: nil} = new_state} ->
        {:reply, {:error, reason}, new_state}

      {:error, _reason, %State{runtime: runtime} = new_state} ->
        {:reply, {:ok, runtime}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        invalidated_state = %State{new_state | module: RuntimeSource.module(), runtime: nil, error: reason}
        {:reply, {:error, reason}, invalidated_state}
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

  defp maybe_reload_current_state(%State{} = state) do
    cond do
      runtime_source_stale?(state) ->
        reload_state(state)

      is_nil(state.runtime) ->
        {:error, state.error, state}

      true ->
        {:ok, state}
    end
  end

  defp reload_state(%State{} = state) do
    module = RuntimeSource.module()

    case module.current() do
      {:ok, runtime} ->
        {:ok, build_state(module, runtime, nil)}

      {:error, reason} ->
        log_reload_error(module, reason)

        {:error, reason,
         %State{
           state
           | module: module,
             error: reason,
             path: runtime_path(module),
             stamp: runtime_stamp(module)
         }}
    end
  end

  defp load_state(module) when is_atom(module) do
    case module.current() do
      {:ok, runtime} -> {:ok, build_state(module, runtime, nil)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_state(module, runtime, error) when is_atom(module) do
    %State{
      module: module,
      runtime: runtime,
      error: error,
      path: runtime_path(module),
      stamp: runtime_stamp(module)
    }
  end

  defp runtime_source_stale?(%State{module: module} = state) do
    current_module = RuntimeSource.module()

    cond do
      current_module != module ->
        true

      current_module == RuntimeSource.FileSource ->
        current_path = runtime_path(current_module)
        current_path != state.path or runtime_stamp(current_module) != state.stamp

      true ->
        false
    end
  end

  defp runtime_path(RuntimeSource.FileSource), do: RuntimeConfig.path()
  defp runtime_path(_module), do: nil

  defp runtime_stamp(RuntimeSource.FileSource) do
    case File.stat(RuntimeConfig.path(), time: :posix) do
      {:ok, stat} -> {stat.mtime, stat.size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_stamp(_module), do: nil

  defp log_reload_error(module, reason) do
    Logger.error("Failed to reload runtime source module=#{inspect(module)} reason=#{inspect(reason)}; keeping last known good runtime")
  end
end
