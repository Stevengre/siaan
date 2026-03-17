defmodule SymphonyElixir.RuntimeConfig do
  @moduledoc """
  Primary API for locating and loading the orchestrator runtime configuration.
  """

  alias SymphonyElixir.{RuntimeConfigStore, RuntimeFile}

  @type loaded_runtime :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec path() :: Path.t()
  defdelegate path(), to: RuntimeFile, as: :file_path

  @spec set_path(Path.t()) :: :ok
  defdelegate set_path(path), to: RuntimeFile, as: :set_file_path

  @spec clear_path() :: :ok
  defdelegate clear_path(), to: RuntimeFile, as: :clear_file_path

  @spec default_paths(Path.t()) :: [Path.t()]
  defdelegate default_paths(root \\ File.cwd!()), to: RuntimeFile, as: :default_runtime_file_paths

  @spec current() :: {:ok, loaded_runtime()} | {:error, term()}
  def current do
    if is_pid(Process.whereis(RuntimeConfigStore)) do
      RuntimeConfigStore.current()
    else
      load()
    end
  end

  @spec load() :: {:ok, loaded_runtime()} | {:error, term()}
  def load do
    case Path.extname(path()) do
      ext when ext in [".yaml", ".yml"] -> SymphonyElixir.RuntimeConfigFile.load(path())
      _ -> RuntimeFile.load(path())
    end
  end

  @spec load(Path.t()) :: {:ok, loaded_runtime()} | {:error, term()}
  def load(path) when is_binary(path) do
    case Path.extname(path) do
      ext when ext in [".yaml", ".yml"] -> SymphonyElixir.RuntimeConfigFile.load(path)
      _ -> RuntimeFile.load(path)
    end
  end
end
