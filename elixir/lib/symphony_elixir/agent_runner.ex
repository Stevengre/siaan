defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  use GenServer
  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.PromptEngine.Continuation
  alias SymphonyElixir.PromptEngine.Renderer
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TrackerIssue
  alias SymphonyElixir.Workspace.Provisioner, as: Workspace

  @type worker_host :: String.t() | nil

  defmodule State do
    @moduledoc false

    defstruct [
      :issue,
      :workspace,
      :worker_host,
      :codex_update_recipient,
      :session,
      port_pending_line: "",
      base_opts: []
    ]
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(
        issue,
        Keyword.get(opts, :worker_host),
        Config.settings!().worker.ssh_hosts
      )

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  @spec start_link(map(), pid() | nil, keyword()) :: GenServer.on_start()
  def start_link(issue, codex_update_recipient \\ nil, opts \\ []) do
    GenServer.start_link(__MODULE__, {issue, codex_update_recipient, opts})
  end

  @spec start(map(), pid() | nil, keyword()) :: GenServer.on_start()
  def start(issue, codex_update_recipient \\ nil, opts \\ []) do
    DynamicSupervisor.start_child(
      SymphonyElixir.AgentRunnerSupervisor,
      {__MODULE__, {issue, codex_update_recipient, opts}}
    )
  end

  @spec dispatch_turn(pid(), map(), keyword()) :: :ok
  def dispatch_turn(pid, issue, opts \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:dispatch_turn, issue, opts})
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  @spec child_spec({map(), pid() | nil, keyword()}) :: Supervisor.child_spec()
  def child_spec({issue, codex_update_recipient, opts}) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [issue, codex_update_recipient, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({issue, codex_update_recipient, opts}) do
    case start_persistent_state(issue, codex_update_recipient, opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:dispatch_turn, issue, opts}, %State{} = state) do
    case run_persistent_dispatch(state, issue, opts) do
      {:ok, updated_state} ->
        send_dispatch_completed(state.codex_update_recipient, issue)
        {:noreply, updated_state}

      {:error, reason} ->
        Logger.error("Persistent agent dispatch failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %State{session: %{port: port}} = state) do
    {:noreply, %{state | port_pending_line: state.port_pending_line <> to_string(chunk)}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %State{session: %{port: port}} = state) do
    line = state.port_pending_line <> to_string(chunk)

    log_idle_port_message(line, state.issue)
    {:noreply, %{state | port_pending_line: ""}}
  end

  def handle_info({port, {:exit_status, status}}, %State{session: %{port: port}} = state) do
    Logger.warning("Persistent app-server exited while idle for #{issue_context(state.issue)}: #{inspect(status)}")
    {:stop, {:app_server_exit, status}, %{state | port_pending_line: ""}}
  end

  @impl true
  def terminate(_reason, %State{session: session}) when is_map(session) do
    AppServer.stop_session(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_persistent_state(issue, codex_update_recipient, opts) do
    worker_hosts =
      candidate_worker_hosts(
        issue,
        Keyword.get(opts, :worker_host),
        Config.settings!().worker.ssh_hosts
      )

    start_persistent_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts)
  end

  defp start_persistent_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case start_persistent_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} when rest != [] ->
        Logger.warning("Persistent agent init failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        start_persistent_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_persistent_on_worker_hosts(_issue, _codex_update_recipient, _opts, []),
    do: {:error, :no_worker_hosts_available}

  defp start_persistent_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)
        allow_external_workspace = Map.get(issue, :project_runtime) in ["local", :local]
        writable_roots = local_runtime_writable_roots(issue, workspace)
        codex_command = Keyword.get(opts, :codex_command)

        with {:ok, session} <-
               AppServer.start_session(
                 workspace,
                 worker_host: worker_host,
                 codex_command: codex_command,
                 allow_external_workspace: allow_external_workspace,
                 writable_roots: writable_roots
               ) do
          {:ok,
           %State{
             issue: issue,
             workspace: workspace,
             worker_host: worker_host,
             codex_update_recipient: codex_update_recipient,
             session: session,
             base_opts: opts
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_persistent_dispatch(%State{} = state, issue, opts) do
    run_opts = Keyword.merge(state.base_opts, opts)
    issue_state_fetcher = Keyword.get(run_opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    max_turns = Keyword.get(run_opts, :max_turns, Config.settings!().agent.max_turns)
    issue_turn_count = Keyword.get(run_opts, :issue_turn_count, 0)

    session =
      if Keyword.get(run_opts, :reuse_physical_session, false) do
        AppServer.mark_physical_session_reuse(state.session)
      else
        state.session
      end

    try do
      with :ok <- Workspace.run_before_run_hook(state.workspace, issue, state.worker_host),
           {:ok, updated_session} <-
             do_run_codex_turns(
               session,
               issue,
               %{
                 workspace: state.workspace,
                 codex_update_recipient: state.codex_update_recipient,
                 opts: run_opts,
                 issue_state_fetcher: issue_state_fetcher,
                 max_turns: max_turns,
                 issue_turn_count: issue_turn_count
               },
               1
             ) do
        {:ok, %{state | issue: issue, session: updated_session}}
      end
    after
      Workspace.run_after_run_hook(state.workspace, issue, state.worker_host)
    end
  end

  defp send_dispatch_completed(recipient, %TrackerIssue{id: issue_id})
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:agent_runner_dispatch_complete, issue_id})
    :ok
  end

  defp send_dispatch_completed(_recipient, _issue), do: :ok

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %TrackerIssue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %TrackerIssue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    issue_turn_count = Keyword.get(opts, :issue_turn_count, 0)
    codex_command = Keyword.get(opts, :codex_command)
    allow_external_workspace = Map.get(issue, :project_runtime) in ["local", :local]
    writable_roots = local_runtime_writable_roots(issue, workspace)

    with {:ok, session} <-
           AppServer.start_session(
             workspace,
             worker_host: worker_host,
             codex_command: codex_command,
             allow_external_workspace: allow_external_workspace,
             writable_roots: writable_roots
           ) do
      try do
        run_context = %{
          workspace: workspace,
          codex_update_recipient: codex_update_recipient,
          opts: opts,
          issue_state_fetcher: issue_state_fetcher,
          max_turns: max_turns,
          issue_turn_count: issue_turn_count
        }

        case do_run_codex_turns(session, issue, run_context, 1) do
          {:ok, _updated_session} -> :ok
          {:error, reason} -> {:error, reason}
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, issue, run_context, turn_number) do
    prompt =
      build_turn_prompt_for_run(
        issue,
        run_context.opts,
        turn_number,
        run_context.max_turns,
        run_context.issue_turn_count,
        app_session
      )

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(run_context.codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{run_context.workspace} turn=#{turn_number}/#{run_context.max_turns}")

      case continue_with_issue?(issue, run_context.issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < run_context.max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{run_context.max_turns}")

          do_run_codex_turns(turn_session.app_session, refreshed_issue, run_context, turn_number + 1)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          {:ok, turn_session.app_session}

        {:done, _refreshed_issue} ->
          {:ok, turn_session.app_session}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt_for_run(issue, opts, 1, _max_turns, 0, _app_session) do
    Continuation.build_turn_prompt(issue, opts, 1, 0, 0, %{}, Renderer)
  end

  defp build_turn_prompt_for_run(_issue, _opts, 1, max_turns, issue_turn_count, %{
         physical_session_reuse_decision: "reused_physical_session"
       }) do
    Continuation.build_reused_physical_session_prompt(issue_turn_count, max_turns)
  end

  defp build_turn_prompt_for_run(issue, opts, 1, max_turns, issue_turn_count, _app_session) do
    Continuation.build_turn_prompt(issue, opts, 1, max_turns, issue_turn_count, %{}, Renderer)
  end

  defp build_turn_prompt_for_run(_issue, _opts, turn_number, max_turns, issue_turn_count, _app_session) do
    Continuation.build_continuation_turn_prompt(turn_number, max_turns, issue_turn_count)
  end

  defp continue_with_issue?(%TrackerIssue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%TrackerIssue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Tracker.active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp local_runtime_writable_roots(%{project_runtime: runtime} = issue, workspace)
       when runtime in ["local", :local] and is_binary(workspace) do
    [workspace, Map.get(issue, :issue_dir), parent_dir(Map.get(issue, :issue_path)), parent_dir(Map.get(issue, :workpad_path))]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp local_runtime_writable_roots(_issue, _workspace), do: []

  defp parent_dir(path) when is_binary(path), do: Path.dirname(path)
  defp parent_dir(_path), do: nil

  defp candidate_worker_hosts(%{project_runtime: runtime}, _preferred_host, _configured_hosts)
       when runtime in ["local", :local],
       do: [nil]

  defp candidate_worker_hosts(_issue, nil, []), do: [nil]

  defp candidate_worker_hosts(_issue, preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%TrackerIssue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_idle_port_message(line, issue) when is_binary(line) do
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
