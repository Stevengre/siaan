defmodule SymphonyElixir.PromptEngine.Renderer do
  @moduledoc """
  Builds agent prompts from tracker issue data.
  """

  alias SymphonyElixir.{Config, RuntimeSource}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.StateSync.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    {template, allowlist} =
      prompt_context!(issue, RuntimeSource.current())

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "allowlist" => allowlist,
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_context!(%{skill_prompts: [_ | _] = skill_prompts}, _workflow_result) do
    allowlist_values =
      case RuntimeSource.current() do
        {:ok, %{config: config}} -> allowlist_values(config)
        _ -> []
      end

    {
      skill_prompts
      |> compose_skill_prompt_template!()
      |> parse_template!(),
      format_allowlist_values(allowlist_values)
    }
  end

  defp prompt_context!(%{prompt_template_path: path}, _workflow_result) when is_binary(path) do
    allowlist_values =
      case RuntimeSource.current() do
        {:ok, %{config: config}} -> allowlist_values(config)
        _ -> []
      end

    {
      path |> File.read!() |> parse_template!(),
      format_allowlist_values(allowlist_values)
    }
  end

  defp prompt_context!(_issue, {:ok, %{config: config, prompt_template: prompt}}) do
    allowlist_values = allowlist_values(config)

    {
      parse_template!(default_prompt(prompt)),
      format_allowlist_values(allowlist_values)
    }
  end

  defp prompt_context!(_issue, {:error, reason}) do
    raise RuntimeError, "runtime_config_unavailable: #{inspect(reason)}"
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp compose_skill_prompt_template!(skill_prompts) when is_list(skill_prompts) do
    ordered_skills = Enum.map_join(skill_prompts, "\n", fn %{name: name} -> "- `#{name}`" end)

    sections =
      Enum.map_join(skill_prompts, "\n\n", fn %{name: name, prompt_template_path: path} ->
        """
        ## Skill: #{name}

        #{File.read!(path)}
        """
      end)

    """
    You are executing a config-driven local workflow state.

    Run the configured skill contracts in this exact order:
    #{ordered_skills}

    Complete each skill in sequence while respecting the file ownership rules described below.

    #{sections}
    """
  end

  defp allowlist_values(config) when is_map(config) do
    values = Map.get(config, "allowlist", Map.get(config, :allowlist, []))

    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_allowlist_values(values) when is_list(values), do: Enum.join(values, ", ")
end

defmodule SymphonyElixir.PromptBuilder do
  @moduledoc false

  alias SymphonyElixir.PromptEngine.Renderer

  defdelegate build_prompt(issue, opts \\ []), to: Renderer
end
