defmodule SymphonyElixir.SessionTracker.Persistence do
  @moduledoc false
  require Logger

  alias SymphonyElixir.Config

  @recent_history_limit 100

  @spec recent_history_limit() :: pos_integer()
  def recent_history_limit, do: @recent_history_limit

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
end
