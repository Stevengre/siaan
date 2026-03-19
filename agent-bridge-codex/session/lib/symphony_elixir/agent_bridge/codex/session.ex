defmodule SymphonyElixir.AgentBridge.Codex.Session do
  @moduledoc false

  require Logger

  alias SymphonyElixir.AgentBridge.{Message, Session}
  alias SymphonyElixir.AgentBridge.Codex.DynamicTool
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @spec start_session(Path.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    codex_command = Keyword.get(opts, :codex_command) || Config.settings!().codex.command
    allow_external_workspace = Keyword.get(opts, :allow_external_workspace, false)

    with {:ok, expanded_workspace} <-
           validate_workspace_cwd(workspace, worker_host, allow_external_workspace),
         {:ok, port} <- start_port(expanded_workspace, worker_host, codex_command) do
      metadata = port_metadata(port, worker_host)
      tracker_kind = Config.settings!().tracker.kind

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts),
           {:ok, thread_state} <-
             do_start_session(port, expanded_workspace, session_policies, tracker_kind) do
        {:ok,
         Session.new(SymphonyElixir.AgentBridge.Codex, %{
           native: %{
             port: port,
             approval_policy: session_policies.approval_policy,
             auto_approve_requests: session_policies.approval_policy == "never",
             thread_sandbox: session_policies.thread_sandbox,
             turn_sandbox_policy: session_policies.turn_sandbox_policy,
             tracker_kind: tracker_kind
           },
           metadata: metadata,
           workspace: expanded_workspace,
           worker_host: worker_host,
           thread_id: thread_state.thread_id,
           physical_session_reuse_decision: thread_state.physical_session_reuse_decision,
           physical_session_fallback_reason: thread_state.physical_session_fallback_reason,
           state: %{port_pending_line: ""}
         })}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec stop_session(Session.t()) :: :ok
  def stop_session(%Session{native: %{port: port}}) when is_port(port), do: stop_port(port)

  @spec mark_physical_session_reuse(Session.t()) :: Session.t()
  def mark_physical_session_reuse(%Session{} = session) do
    %{
      session
      | physical_session_reuse_decision: "reused_physical_session",
        physical_session_fallback_reason: nil
    }
  end

  @spec handle_transport_message(Session.t(), term(), map()) ::
          {:handled, Session.t()} | {:stop, term(), Session.t()} | :unhandled
  def handle_transport_message(
        %Session{native: %{port: port}, state: %{port_pending_line: pending_line}} = session,
        {port, {:data, {:noeol, chunk}}},
        _issue
      ) do
    {:handled, put_in(session.state.port_pending_line, pending_line <> to_string(chunk))}
  end

  def handle_transport_message(
        %Session{native: %{port: port}, state: %{port_pending_line: pending_line}} = session,
        {port, {:data, {:eol, chunk}}},
        issue
      ) do
    log_idle_transport_message(pending_line <> to_string(chunk), issue)
    {:handled, put_in(session.state.port_pending_line, "")}
  end

  def handle_transport_message(
        %Session{native: %{port: port}} = session,
        {port, {:exit_status, status}},
        issue
      ) do
    Logger.warning("Persistent app-server exited while idle for #{issue_context(issue)}: #{inspect(status)}")
    {:stop, {:app_server_exit, status}, put_in(session.state.port_pending_line, "")}
  end

  def handle_transport_message(_session, _message, _issue), do: :unhandled

  @spec send_message(port(), map()) :: true
  def send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  @spec await_response(port(), integer()) :: {:ok, map()} | {:error, term()}
  def await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  @spec emit_message((map() -> term()), atom(), map(), map()) :: term()
  def emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    on_message.(Message.build(event, details, metadata))
  end

  @spec metadata_from_message(port(), map()) :: map()
  def metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  @spec default_on_message(map()) :: :ok
  def default_on_message(_message), do: :ok

  @spec log_non_json_stream_line(term(), String.t()) :: :ok
  def log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end

    :ok
  end

  defp validate_workspace_cwd(workspace, nil, allow_external_workspace)
       when is_binary(workspace) and is_boolean(allow_external_workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        allow_external_workspace ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, _allow_external_workspace)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, codex_command) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      {:ok,
       Port.open(
         {:spawn_executable, String.to_charlist(executable)},
         [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           args: [~c"-lc", String.to_charlist(codex_command)],
           cd: String.to_charlist(workspace),
           line: @port_line_bytes
         ]
       )}
    end
  end

  defp start_port(workspace, worker_host, codex_command) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{codex_command}"
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp session_policies(workspace, nil, opts) do
    Config.codex_runtime_settings(workspace, writable_roots: Keyword.get(opts, :writable_roots, []))
  end

  defp session_policies(workspace, worker_host, _opts) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, tracker_kind) do
    case send_initialize(port) do
      :ok -> initialize_thread_state(port, workspace, session_policies, tracker_kind)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_initialize(port) do
    send_message(port, %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{"experimentalApi" => true},
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    })

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp initialize_thread_state(port, workspace, session_policies, tracker_kind) do
    with {:ok, thread_id} <- start_thread(port, workspace, session_policies, tracker_kind) do
      {:ok,
       %{
         thread_id: thread_id,
         physical_session_reuse_decision: "started_new_physical_session",
         physical_session_fallback_reason: nil
       }}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         tracker_kind
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs(tracker_kind: tracker_kind)
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => thread_id}}} -> {:ok, thread_id}
      {:ok, %{"thread" => thread_payload}} -> {:error, {:invalid_thread_payload, thread_payload}}
      other -> other
    end
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response(port, request_id, pending_line <> to_string(chunk), timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)
    if is_map(usage), do: Map.put(metadata, :usage, usage), else: metadata
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_idle_transport_message(line, issue) when is_binary(line) do
    payload = String.trim(line)

    if payload != "" do
      case Jason.decode(payload) do
        {:ok, %{"method" => method}} when is_binary(method) ->
          Logger.debug("Ignoring idle app-server notification for #{issue_context(issue)}: #{method}")

        {:ok, %{"id" => id}} ->
          Logger.debug("Ignoring idle app-server response for #{issue_context(issue)}: #{inspect(id)}")

        {:ok, decoded} ->
          Logger.debug("Ignoring idle app-server payload for #{issue_context(issue)}: #{inspect(decoded)}")

        {:error, _reason} ->
          Logger.debug("Ignoring idle app-server stream line for #{issue_context(issue)}: #{payload}")
      end
    end
  end
end
