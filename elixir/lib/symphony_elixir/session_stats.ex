defmodule SymphonyElixir.SessionStats do
  @moduledoc false

  alias SymphonyElixir.Config

  @recent_history_limit 100
  @pricing_source "OpenAI API pricing snapshot 2026-03-16"
  @pricing_by_model %{
    "gpt-5" => %{input_per_million_usd: 1.25, output_per_million_usd: 10.0},
    "gpt-5-mini" => %{input_per_million_usd: 0.25, output_per_million_usd: 2.0},
    "gpt-5-codex" => %{input_per_million_usd: 1.25, output_per_million_usd: 10.0},
    "gpt-5.1-codex" => %{input_per_million_usd: 1.25, output_per_million_usd: 10.0},
    "gpt-5.2-codex" => %{input_per_million_usd: 1.25, output_per_million_usd: 10.0},
    "gpt-5.3-codex" => %{input_per_million_usd: 1.75, output_per_million_usd: 14.0},
    "codex-mini-latest" => %{input_per_million_usd: 1.5, output_per_million_usd: 6.0}
  }

  @spec recent_history_limit() :: pos_integer()
  def recent_history_limit, do: @recent_history_limit

  @spec app_version() :: String.t()
  def app_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  @spec configured_model() :: String.t() | nil
  def configured_model do
    command = Config.settings!().codex.command

    case Regex.run(~r/(?:^|\s)--model\s+([^\s]+)/, command, capture: :all_but_first) do
      [model] -> model
      _ -> nil
    end
  end

  @spec load_recent_history(non_neg_integer()) :: [map()]
  def load_recent_history(limit \\ @recent_history_limit) when is_integer(limit) and limit >= 0 do
    history_path()
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.take(-limit)
        |> Enum.map(&Jason.decode!/1)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  @spec append_history_record(map()) :: :ok | {:error, term()}
  def append_history_record(record) when is_map(record) do
    path = history_path()
    :ok = File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(record) <> "\n", [:append])
  end

  @spec build_running_summary(map()) :: map()
  def build_running_summary(running_entry) when is_map(running_entry) do
    input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    model = Map.get(running_entry, :codex_model)
    cost = estimate_cost(model, input_tokens, output_tokens)

    %{
      siaan_version: Map.get(running_entry, :siaan_version, app_version()),
      model: model,
      pricing_model: cost.pricing_model,
      pricing_source: cost.pricing_source,
      estimated_cost_usd: cost.estimated_cost_usd,
      estimated_input_cost_usd: cost.estimated_input_cost_usd,
      estimated_output_cost_usd: cost.estimated_output_cost_usd,
      cost_estimate_available: cost.cost_estimate_available
    }
  end

  @spec build_completed_record(map(), String.t()) :: map()
  def build_completed_record(running_entry, result) when is_map(running_entry) and is_binary(result) do
    input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    model = Map.get(running_entry, :codex_model)
    started_at = Map.get(running_entry, :started_at)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    cost = estimate_cost(model, input_tokens, output_tokens)

    %{
      "issue_id" => Map.get(running_entry, :issue_id),
      "issue_identifier" => Map.get(running_entry, :identifier),
      "session_id" => Map.get(running_entry, :session_id),
      "result" => result,
      "siaan_version" => Map.get(running_entry, :siaan_version, app_version()),
      "model" => model,
      "pricing_model" => cost.pricing_model,
      "pricing_source" => cost.pricing_source,
      "turn_count" => Map.get(running_entry, :turn_count, 0),
      "started_at" => iso8601(started_at),
      "completed_at" => DateTime.to_iso8601(completed_at),
      "runtime_seconds" => running_seconds(started_at, completed_at),
      "tokens" => %{
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "total_tokens" => total_tokens
      },
      "cost" => %{
        "estimated_cost_usd" => cost.estimated_cost_usd,
        "estimated_input_cost_usd" => cost.estimated_input_cost_usd,
        "estimated_output_cost_usd" => cost.estimated_output_cost_usd,
        "cost_estimate_available" => cost.cost_estimate_available
      }
    }
  end

  @spec estimate_cost(String.t() | nil, integer(), integer()) :: map()
  def estimate_cost(model, input_tokens, output_tokens) do
    normalized_model =
      model
      |> to_string_or_nil()
      |> case do
        nil -> nil
        value -> String.trim(value)
      end

    case Map.get(@pricing_by_model, normalized_model) do
      %{input_per_million_usd: input_rate, output_per_million_usd: output_rate} ->
        input_cost = usd(input_tokens * input_rate / 1_000_000)
        output_cost = usd(output_tokens * output_rate / 1_000_000)

        %{
          pricing_model: normalized_model,
          pricing_source: @pricing_source,
          estimated_input_cost_usd: input_cost,
          estimated_output_cost_usd: output_cost,
          estimated_cost_usd: usd(input_cost + output_cost),
          cost_estimate_available: true
        }

      _ ->
        %{
          pricing_model: normalized_model,
          pricing_source: nil,
          estimated_input_cost_usd: nil,
          estimated_output_cost_usd: nil,
          estimated_cost_usd: nil,
          cost_estimate_available: false
        }
    end
  end

  defp history_path do
    workspace_root =
      Config.settings!().workspace.root
      |> expand_home_path()
      |> Path.expand()

    Path.join(workspace_root, ".siaan/session-stats.ndjson")
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = completed_at) do
    max(0, DateTime.diff(completed_at, started_at, :second))
  end

  defp running_seconds(_started_at, _completed_at), do: 0

  defp iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601(_timestamp), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp expand_home_path("~"), do: System.user_home() || "~"

  defp expand_home_path("~/" <> rest) do
    case System.user_home() do
      nil -> "~/" <> rest
      home -> Path.join(home, rest)
    end
  end

  defp expand_home_path(path), do: path

  defp usd(value) when is_number(value) do
    value
    |> Decimal.from_float()
    |> Decimal.round(6)
    |> Decimal.to_float()
  end
end
