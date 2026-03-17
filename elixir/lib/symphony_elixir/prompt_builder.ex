defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    {template, allowlist} =
      prompt_context!(issue, Workflow.current())

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

  defp prompt_context!(%{prompt_template_path: path}, _workflow_result) when is_binary(path) do
    allowlist_values =
      case Workflow.current() do
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
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
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

  defp allowlist_values(config) when is_map(config) do
    values = Map.get(config, "allowlist", Map.get(config, :allowlist, []))

    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_allowlist_values(values) when is_list(values), do: Enum.join(values, ", ")
end
