defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Compatibility wrapper around `RuntimeConfigStore`.
  """

  alias SymphonyElixir.RuntimeConfigStore

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    RuntimeConfigStore.start_link(Keyword.put(opts, :name, __MODULE__))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @spec current() :: {:ok, SymphonyElixir.RuntimeConfig.loaded_runtime()} | {:error, term()}
  def current, do: RuntimeConfigStore.current(__MODULE__)

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload, do: RuntimeConfigStore.force_reload(__MODULE__)

  @spec init(keyword()) :: {:ok, struct()} | {:stop, term()}
  def init(opts), do: RuntimeConfigStore.init(opts)

  @spec handle_call(term(), {pid(), term()}, struct()) ::
          {:reply, term(), struct()}
  def handle_call(message, from, state), do: RuntimeConfigStore.handle_call(message, from, state)

  @spec handle_info(term(), struct()) ::
          {:noreply, struct()}
  def handle_info(message, state), do: RuntimeConfigStore.handle_info(message, state)
end
