defmodule SymphonyElixir.RuntimeConfigFile do
  @moduledoc """
  Loads runtime configuration from a standalone YAML file.
  """

  alias SymphonyElixir.RuntimeStateConfig

  @type loaded_runtime_config :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @prompt_keys ["prompt", "prompt_template", "prompt_template_path"]

  @spec load(Path.t()) :: {:ok, loaded_runtime_config()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(contents),
         :ok <- ensure_map(decoded),
         {:ok, prompt_template} <- resolve_prompt_template(decoded, path) do
      {:ok,
       %{
         config: decoded |> Map.drop(@prompt_keys) |> RuntimeStateConfig.normalize(),
         prompt: prompt_template,
         prompt_template: prompt_template
       }}
    else
      {:error, reason} ->
        normalize_error(path, reason)
    end
  end

  defp ensure_map(decoded) when is_map(decoded), do: :ok
  defp ensure_map(_decoded), do: {:error, :workflow_not_a_map}

  defp resolve_prompt_template(decoded, path) when is_map(decoded) and is_binary(path) do
    cond do
      is_binary(decoded["prompt_template_path"]) ->
        prompt_path =
          path
          |> Path.dirname()
          |> Path.join(decoded["prompt_template_path"])
          |> Path.expand()

        case File.read(prompt_path) do
          {:ok, prompt_template} -> {:ok, prompt_template}
          {:error, reason} -> {:error, {:missing_prompt_template_file, prompt_path, reason}}
        end

      is_binary(decoded["prompt_template"]) ->
        {:ok, decoded["prompt_template"]}

      is_binary(decoded["prompt"]) ->
        {:ok, decoded["prompt"]}

      true ->
        {:ok, ""}
    end
  end

  defp normalize_error(path, :enoent), do: {:error, {:missing_workflow_file, path, :enoent}}
  defp normalize_error(_path, {:missing_prompt_template_file, _, _} = reason), do: {:error, reason}
  defp normalize_error(_path, :workflow_not_a_map), do: {:error, :workflow_not_a_map}
  defp normalize_error(_path, reason), do: {:error, {:workflow_parse_error, reason}}
end
