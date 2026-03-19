defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Compatibility wrapper around the default runtime markdown file loader.
  """

  alias SymphonyElixir.RuntimeConfig

  @spec workflow_file_path() :: Path.t()
  defdelegate workflow_file_path(), to: RuntimeConfig, as: :path

  @spec set_workflow_file_path(Path.t()) :: :ok
  defdelegate set_workflow_file_path(path), to: RuntimeConfig, as: :set_path

  @spec clear_workflow_file_path() :: :ok
  defdelegate clear_workflow_file_path(), to: RuntimeConfig, as: :clear_path

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  defdelegate current(), to: RuntimeConfig

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  defdelegate load(), to: RuntimeConfig

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  defdelegate load(path), to: RuntimeConfig
end
