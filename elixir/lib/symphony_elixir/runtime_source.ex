defmodule SymphonyElixir.RuntimeSource do
  @moduledoc """
  Runtime source boundary for loading config and prompt data for the orchestrator.
  """

  alias SymphonyElixir.{RuntimeConfig, RuntimeSourceStore}

  @type loaded_runtime :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @callback current() :: {:ok, loaded_runtime()} | {:error, term()}

  @spec current() :: {:ok, loaded_runtime()} | {:error, term()}
  def current do
    case Process.whereis(RuntimeSourceStore) do
      pid when is_pid(pid) ->
        try do
          RuntimeSourceStore.current()
        catch
          :exit, _reason -> module().current()
        end

      _ ->
        module().current()
    end
  end

  @spec module() :: module()
  def module do
    Application.get_env(:symphony_elixir, :runtime_source_module, __MODULE__.FileSource)
  end

  defmodule FileSource do
    @moduledoc false
    @behaviour SymphonyElixir.RuntimeSource

    @impl true
    def current do
      RuntimeConfig.load()
    end
  end
end
