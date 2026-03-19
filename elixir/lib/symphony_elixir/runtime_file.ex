defmodule SymphonyElixir.RuntimeFile do
  @moduledoc """
  Loads runtime configuration and prompt content from the legacy markdown file format.
  """

  alias SymphonyElixir.{RuntimeConfigStore, RuntimeSourceStore, WorkflowStore}

  @default_runtime_file_names ["runtime.yaml", "runtime.yml", "WORKFLOW.md"]

  @type loaded_runtime_file :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec file_path() :: Path.t()
  def file_path do
    Application.get_env(:symphony_elixir, :runtime_config_path) ||
      Application.get_env(:symphony_elixir, :workflow_file_path) ||
      default_runtime_file_path()
  end

  @spec set_file_path(Path.t()) :: :ok
  def set_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :runtime_config_path, path)
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_stores()
    :ok
  end

  @spec clear_file_path() :: :ok
  def clear_file_path do
    Application.delete_env(:symphony_elixir, :runtime_config_path)
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_stores()
    :ok
  end

  @spec default_runtime_file_paths(Path.t()) :: [Path.t()]
  def default_runtime_file_paths(root \\ File.cwd!()) when is_binary(root) do
    Enum.map(@default_runtime_file_names, &Path.join(root, &1))
  end

  @spec load() :: {:ok, loaded_runtime_file()} | {:error, term()}
  def load do
    load(file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_runtime_file()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec parse(String.t()) :: {:ok, loaded_runtime_file()} | {:error, term()}
  def parse(content) when is_binary(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: normalize_state_config(front_matter),
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp normalize_state_config(%{"state" => state} = config) when is_map(state) do
    Map.put(config, "state", normalize_state_section(state))
  end

  defp normalize_state_config(%{"tracker" => tracker} = config) when is_map(tracker) do
    config
    |> Map.delete("tracker")
    |> Map.put("state", normalize_state_section(tracker))
  end

  defp normalize_state_config(config), do: config

  defp normalize_state_section(%{"type" => _type} = state), do: state

  defp normalize_state_section(%{"kind" => kind} = state) do
    state
    |> Map.delete("kind")
    |> Map.put("type", kind)
  end

  defp normalize_state_section(state), do: state

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_stores do
    if Process.whereis(RuntimeSourceStore) do
      _ = RuntimeSourceStore.force_reload()
    end

    if Process.whereis(RuntimeConfigStore) do
      _ = RuntimeConfigStore.force_reload()
    end

    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end

  defp default_runtime_file_path do
    default_runtime_file_paths()
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> Path.join(File.cwd!(), List.first(@default_runtime_file_names))
      path -> path
    end
  end
end
