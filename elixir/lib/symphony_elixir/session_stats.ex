defmodule SymphonyElixir.SessionStats do
  @moduledoc false
  require Logger

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
    configured_model(Config.settings!().codex.command)
  end

  @spec configured_model(String.t() | nil) :: String.t() | nil
  def configured_model(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> configured_model_from_args()
  end

  def configured_model(_command), do: nil

  @spec load_recent_history(non_neg_integer()) :: [map()]
  def load_recent_history(limit \\ @recent_history_limit) when is_integer(limit) and limit >= 0 do
    history_path()
    |> File.read()
    |> case do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_history_line/1)
        |> Enum.take(-limit)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  @spec append_history_record(map()) :: :ok | {:error, term()}
  def append_history_record(record) when is_map(record) do
    path = history_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(record) do
      File.write(path, encoded <> "\n", [:append])
    end
  end

  @spec load_issue_session(String.t()) :: map() | nil
  def load_issue_session(issue_id) when is_binary(issue_id) do
    load_issue_sessions()
    |> Map.get(issue_id)
  end

  def load_issue_session(_issue_id), do: nil

  @spec load_issue_sessions() :: map()
  def load_issue_sessions do
    issue_sessions_path()
    |> File.read()
    |> case do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, _reason} ->
        %{}
    end
  end

  @spec save_issue_session(map()) :: :ok | {:error, term()}
  def save_issue_session(%{"issue_id" => issue_id} = record) when is_binary(issue_id) do
    update_issue_sessions(fn sessions ->
      Map.put(sessions, issue_id, record)
    end)
  end

  def save_issue_session(_record), do: {:error, :invalid_issue_session_record}

  @spec delete_issue_session(String.t()) :: :ok | {:error, term()}
  def delete_issue_session(issue_id) when is_binary(issue_id) do
    update_issue_sessions(fn sessions ->
      Map.delete(sessions, issue_id)
    end)
  end

  def delete_issue_session(_issue_id), do: {:error, :invalid_issue_id}

  @spec consume_pending_transition(String.t()) :: String.t() | nil
  def consume_pending_transition(issue_id) when is_binary(issue_id) do
    consume_pending_transition(issue_id, &load_issue_session/1, &save_issue_session/1)
  end

  def consume_pending_transition(_issue_id), do: nil

  @doc false
  @spec consume_pending_transition_for_test(
          String.t(),
          (String.t() -> map() | nil),
          (map() -> :ok | {:error, term()})
        ) :: String.t() | nil
  def consume_pending_transition_for_test(issue_id, load_issue_session_fun, save_issue_session_fun)
      when is_binary(issue_id) and is_function(load_issue_session_fun, 1) and
             is_function(save_issue_session_fun, 1) do
    consume_pending_transition(issue_id, load_issue_session_fun, save_issue_session_fun)
  end

  defp consume_pending_transition(issue_id, load_issue_session_fun, save_issue_session_fun)
       when is_binary(issue_id) and is_function(load_issue_session_fun, 1) and
              is_function(save_issue_session_fun, 1) do
    issue_session = load_issue_session_fun.(issue_id)

    case issue_session do
      %{"pending_transition" => transition} = record when is_binary(transition) ->
        updated_record = Map.delete(record, "pending_transition")

        case save_issue_session_fun.(updated_record) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Unable to clear pending transition for issue_id=#{issue_id}: #{inspect(reason)}")

            :ok
        end

        transition

      _ ->
        nil
    end
  end

  @spec mark_pending_transition(String.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def mark_pending_transition(issue_id, issue_identifier, transition)
      when is_binary(issue_id) and is_binary(transition) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    record =
      load_issue_session(issue_id) ||
        %{
          "issue_id" => issue_id,
          "issue_identifier" => issue_identifier
        }

    record
    |> Map.put("issue_identifier", issue_identifier || record["issue_identifier"])
    |> Map.put("pending_transition", transition)
    |> Map.put("updated_at", now)
    |> save_issue_session()
  end

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

  defp history_path do
    workspace_root =
      Config.settings!().workspace.root
      |> expand_home_path()
      |> Path.expand()

    Path.join(workspace_root, ".siaan/session-stats.ndjson")
  end

  defp issue_sessions_path do
    workspace_root =
      Config.settings!().workspace.root
      |> expand_home_path()
      |> Path.expand()

    Path.join(workspace_root, ".siaan/issue-sessions.json")
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = completed_at) do
    max(0, DateTime.diff(completed_at, started_at, :second))
  end

  defp running_seconds(_started_at, _completed_at), do: 0

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

  defp decode_history_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> [decoded]
      {:error, _reason} -> []
    end
  end

  defp update_issue_sessions(update_fun) when is_function(update_fun, 1) do
    path = issue_sessions_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         current <- load_issue_sessions(),
         {:ok, encoded} <- Jason.encode(update_fun.(current)) do
      File.write(path, encoded)
    end
  end

  defp expand_home_path("~"), do: System.user_home() || "~"

  defp expand_home_path("~/" <> rest), do: Path.join(System.user_home() || "~", rest)

  defp expand_home_path(path), do: path

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
end
