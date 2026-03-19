defmodule SymphonyElixir.RuntimeStateConfig do
  @moduledoc false

  @spec normalize(map()) :: map()
  def normalize(%{"state" => state} = config) when is_map(state) do
    Map.put(config, "state", normalize_section(state))
  end

  def normalize(%{"tracker" => tracker} = config) when is_map(tracker) do
    config
    |> Map.delete("tracker")
    |> Map.put("state", normalize_section(tracker))
  end

  def normalize(config), do: config

  defp normalize_section(%{"type" => _type} = state), do: state

  defp normalize_section(%{"kind" => kind} = state) do
    state
    |> Map.delete("kind")
    |> Map.put("type", kind)
  end

  defp normalize_section(state), do: state
end
