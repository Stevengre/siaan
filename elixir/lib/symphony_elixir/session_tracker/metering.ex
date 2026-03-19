defmodule SymphonyElixir.SessionTracker.Metering do
  @moduledoc false

  alias SymphonyElixir.Config

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

  @spec app_version() :: String.t()
  def app_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  @spec configured_model() :: String.t() | nil
  def configured_model do
    configured_model(Config.settings!().codex.command)
  end

  @spec configured_model(String.t() | nil) :: String.t() | nil
  def configured_model(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> configured_model_from_args()
  end

  def configured_model(_command), do: nil

  @spec build_running_summary(map()) :: map()
  def build_running_summary(running_entry) when is_map(running_entry) do
    input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    model = Map.get(running_entry, :codex_model)
    cost = estimate_cost(model, input_tokens, output_tokens)
    git = workspace_git_metadata(Map.get(running_entry, :workspace_path))

    %{
      siaan_version: Map.get(running_entry, :siaan_version, app_version()),
      model: model,
      repo_head_sha: git.repo_head_sha,
      repo_branch: git.repo_branch,
      pricing_model: cost.pricing_model,
      pricing_source: cost.pricing_source,
      estimated_cost_usd: cost.estimated_cost_usd,
      estimated_input_cost_usd: cost.estimated_input_cost_usd,
      estimated_output_cost_usd: cost.estimated_output_cost_usd,
      cost_estimate_available: cost.cost_estimate_available,
      issue_session_id: Map.get(running_entry, :issue_session_id),
      execution_profile: Map.get(running_entry, :execution_profile),
      execution_transition: Map.get(running_entry, :execution_transition),
      session_reuse_policy: Map.get(running_entry, :session_reuse_policy),
      session_reuse_decision: Map.get(running_entry, :session_reuse_decision),
      physical_session_reuse_decision: Map.get(running_entry, :physical_session_reuse_decision),
      physical_session_fallback_reason: Map.get(running_entry, :physical_session_fallback_reason),
      physical_session_id: Map.get(running_entry, :codex_thread_id),
      physical_session_count: Map.get(running_entry, :physical_session_count, 0),
      issue_session_turn_count: Map.get(running_entry, :issue_session_turn_count, 0)
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
    git = workspace_git_metadata(Map.get(running_entry, :workspace_path))

    %{
      "issue_id" => Map.get(running_entry, :issue_id),
      "issue_identifier" => Map.get(running_entry, :identifier),
      "session_id" => Map.get(running_entry, :session_id),
      "issue_session_id" => Map.get(running_entry, :issue_session_id),
      "result" => result,
      "siaan_version" => Map.get(running_entry, :siaan_version, app_version()),
      "model" => model,
      "execution_profile" => Map.get(running_entry, :execution_profile),
      "execution_transition" => Map.get(running_entry, :execution_transition),
      "session_reuse_policy" => Map.get(running_entry, :session_reuse_policy),
      "session_reuse_decision" => Map.get(running_entry, :session_reuse_decision),
      "physical_session_reuse_decision" => Map.get(running_entry, :physical_session_reuse_decision),
      "physical_session_fallback_reason" => Map.get(running_entry, :physical_session_fallback_reason),
      "physical_session_id" => Map.get(running_entry, :codex_thread_id),
      "physical_session_count" => Map.get(running_entry, :physical_session_count, 0),
      "repo_head_sha" => git.repo_head_sha,
      "repo_branch" => git.repo_branch,
      "pricing_model" => cost.pricing_model,
      "pricing_source" => cost.pricing_source,
      "turn_count" => Map.get(running_entry, :turn_count, 0),
      "issue_session_turn_count" => Map.get(running_entry, :issue_session_turn_count, 0),
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

  @spec workspace_git_metadata(Path.t() | nil) :: %{repo_head_sha: String.t() | nil, repo_branch: String.t() | nil}
  def workspace_git_metadata(workspace_path) when is_binary(workspace_path) and workspace_path != "" do
    expanded_workspace =
      workspace_path
      |> expand_home_path()
      |> Path.expand()

    %{
      repo_head_sha: git_output(expanded_workspace, ["rev-parse", "HEAD"]),
      repo_branch: git_output(expanded_workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
    }
  end

  def workspace_git_metadata(_workspace_path), do: %{repo_head_sha: nil, repo_branch: nil}

  @spec integrate_codex_update(map(), map()) :: {map(), map()}
  def integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        codex_thread_id: physical_session_id_for_update(Map.get(running_entry, :codex_thread_id), update),
        physical_session_reuse_decision:
          physical_session_reuse_decision_for_update(
            Map.get(running_entry, :physical_session_reuse_decision),
            update
          ),
        physical_session_fallback_reason:
          physical_session_fallback_reason_for_update(
            Map.get(running_entry, :physical_session_fallback_reason),
            update
          ),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        issue_session_turn_count:
          turn_count_for_update(
            Map.get(running_entry, :issue_session_turn_count, 0),
            running_entry.session_id,
            update
          ),
        physical_session_count:
          physical_session_count_for_update(
            Map.get(running_entry, :physical_session_count, 0),
            Map.get(running_entry, :codex_thread_id),
            update
          )
      }),
      token_delta
    }
  end

  @spec apply_token_delta(map(), map()) :: map()
  def apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  @spec extract_rate_limits(map()) :: map() | nil
  def extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  @spec running_seconds(DateTime.t() | term(), DateTime.t() | term()) :: non_neg_integer()
  def running_seconds(%DateTime{} = started_at, %DateTime{} = completed_at) do
    max(0, DateTime.diff(completed_at, started_at, :second))
  end

  def running_seconds(_started_at, _completed_at), do: 0

  defp iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601(_timestamp), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp configured_model_from_args(["--model", model | rest]) do
    normalize_model(model) || configured_model_from_args(rest)
  end

  defp configured_model_from_args(["--model=" <> model | rest]) do
    normalize_model(model) || configured_model_from_args(rest)
  end

  defp configured_model_from_args([_arg | rest]), do: configured_model_from_args(rest)
  defp configured_model_from_args([]), do: nil

  defp expand_home_path("~"), do: System.user_home() || "~"
  defp expand_home_path("~/" <> rest), do: Path.join(System.user_home() || "~", rest)
  defp expand_home_path(path), do: path

  defp git_output(workspace_path, args) when is_binary(workspace_path) and is_list(args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> nil
          value -> value
        end

      {_output, _status} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp normalize_model(model) when is_binary(model) do
    model
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp usd(value) when is_number(value) do
    value
    |> Decimal.from_float()
    |> Decimal.round(6)
    |> Decimal.to_float()
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp physical_session_id_for_update(_existing, %{thread_id: thread_id})
       when is_binary(thread_id),
       do: thread_id

  defp physical_session_id_for_update(existing, _update), do: existing

  defp physical_session_reuse_decision_for_update(_existing, %{
         physical_session_reuse_decision: decision
       })
       when is_binary(decision),
       do: decision

  defp physical_session_reuse_decision_for_update(existing, _update), do: existing

  defp physical_session_fallback_reason_for_update(_existing, %{
         physical_session_fallback_reason: reason
       })
       when is_binary(reason),
       do: reason

  defp physical_session_fallback_reason_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp physical_session_count_for_update(existing_count, existing_thread_id, %{
         event: :session_started,
         thread_id: thread_id
       })
       when is_integer(existing_count) and is_binary(thread_id) do
    if thread_id == existing_thread_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp physical_session_count_for_update(existing_count, _existing_thread_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp physical_session_count_for_update(_existing_count, _existing_thread_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
