defmodule SymphonyElixir.Local.Adapter do
  @moduledoc """
  Local-file-backed tracker adapter used by the orchestrator.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Local.{Issue, ProjectConfig, Workflow}
  alias SymphonyElixir.TrackerIssue

  @directory_states MapSet.new(["in-progress", "review", "done"])

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, context} <- load_context(),
         {:ok, issues} <-
           Issue.scan_root(
             context.root_path,
             context.project.dir,
             context.workflow,
             context.project.runtime
           ) do
      active_states =
        active_states()
        |> Enum.map(&normalize_tracker_state/1)
        |> MapSet.new()

      with {:ok, transitioned_issues} <-
             issues
             |> Enum.filter(&passes_adapter_filters?(&1, context.project.adapter))
             |> apply_transitions(context) do
        transitioned_issues
        |> Enum.filter(
          &(MapSet.member?(active_states, normalize_tracker_state(&1.state)) and
              dispatchable_activity?(&1, context.workflow))
        )
        |> then(&{:ok, &1})
      end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    wanted =
      states
      |> Enum.map(&normalize_tracker_state/1)
      |> MapSet.new()

    with {:ok, context} <- load_context(),
         {:ok, issues} <-
           Issue.scan_root(
             context.root_path,
             context.project.dir,
             context.workflow,
             context.project.runtime
           ) do
      with {:ok, transitioned_issues} <-
             issues
             |> Enum.filter(&passes_adapter_filters?(&1, context.project.adapter))
             |> apply_transitions(context) do
        transitioned_issues
        |> Enum.filter(&MapSet.member?(wanted, normalize_tracker_state(&1.state)))
        |> then(&{:ok, &1})
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, context} <- load_context(),
         {:ok, issues} <- collect_issue_states(issue_ids, context) do
      {:ok, Enum.reverse(issues)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: :ok

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, target_state) do
    normalized_target = normalize_storage_state(target_state)

    with {:ok, context} <- load_context(),
         {:ok, issue} <-
           Issue.load_by_slug(
             context.root_path,
             issue_id,
             context.project.dir,
             context.workflow,
             context.project.runtime
           ),
         {:ok, transition} <-
           Workflow.first_matching_transition_to(
             context.workflow,
             normalize_storage_state(issue.state),
             normalized_target,
             issue.issue_path
           ),
         :ok <- ensure_transition(transition, issue.state, target_state) do
      move_issue(issue, normalized_target, context.root_path)
    end
  end

  @spec active_states() :: [String.t()]
  def active_states do
    case load_context() do
      {:ok, context} ->
        context.workflow
        |> active_workflow_state_names()
        |> Enum.map(&Issue.tracker_state_from_storage_state/1)
        |> fallback_active_states_if_empty()

      {:error, _reason} ->
        fallback_active_states()
    end
  end

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: Config.settings!().tracker.terminal_states || []

  @spec dispatch_target_state(TrackerIssue.t() | String.t() | nil) :: String.t() | nil
  def dispatch_target_state(%TrackerIssue{state: issue_state, issue_path: issue_path}) do
    normalized_state = normalize_storage_state(issue_state)

    with {:ok, context} <- load_context(),
         true <- is_binary(issue_path),
         {:ok, %Workflow.Transition{to: target_state}} <-
           Workflow.first_matching_transition(context.workflow, normalized_state, issue_path) do
      Issue.tracker_state_from_storage_state(target_state)
    else
      _ -> dispatch_target_state(issue_state)
    end
  end

  def dispatch_target_state(issue_state) when is_binary(issue_state) do
    normalized_state = normalize_storage_state(issue_state)

    with {:ok, context} <- load_context(),
         %{transitions: [%Workflow.Transition{to: target_state} | _]} <- Map.get(context.workflow, normalized_state) do
      Issue.tracker_state_from_storage_state(target_state)
    else
      _ -> fallback_dispatch_target_state(issue_state)
    end
  end

  def dispatch_target_state(_issue_state), do: nil

  @spec initial_dispatch_transition_name() :: String.t() | nil
  def initial_dispatch_transition_name do
    with {:ok, context} <- load_context(),
         ready_state when is_binary(ready_state) <- dispatch_entry_state(context.workflow),
         target_state when is_binary(target_state) <-
           dispatch_target_state(Issue.tracker_state_from_storage_state(ready_state)) do
      SymphonyElixir.DispatchLifecycle.transition_name(
        Issue.tracker_state_from_storage_state(ready_state),
        target_state
      )
    else
      _ ->
        fallback_initial_dispatch_transition_name()
    end
  end

  @spec reconcile_watch_states(
          (String.t(), String.t() -> term()),
          (String.t(), String.t() | nil, String.t() -> term())
        ) :: :ok | {:error, term()}
  def reconcile_watch_states(_update_issue_state_fun, _mark_pending_transition_fun), do: :ok

  defp load_context do
    settings = Config.settings!()
    tracker = settings.tracker

    config_path =
      tracker.local_config_path ||
        Path.join(System.user_home!(), ".config/skills/issue-config/config.toml")

    project_name = tracker.local_project || "siaan"

    with {:ok, project} <- ProjectConfig.load(config_path, project_name),
         {:ok, workflow} <- Workflow.load(project.workflow) do
      {:ok, %{project: project, workflow: workflow, root_path: Path.dirname(config_path)}}
    end
  end

  defp workflow_state_names(workflow) when is_map(workflow) do
    workflow
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
  end

  defp active_workflow_state_names(workflow) when is_map(workflow) do
    workflow
    |> workflow_state_names()
    |> Enum.filter(&active_workflow_state?(workflow, &1))
  end

  defp active_workflow_state?(workflow, state_name) when is_binary(state_name) do
    workflow
    |> Map.get(state_name, %{activities: []})
    |> Map.get(:activities, [])
    |> Enum.any?(&skill_activity?/1)
  end

  defp dispatch_entry_state(workflow) when is_map(workflow) do
    state_names = workflow_state_names(workflow)

    if "ready" in state_names do
      "ready"
    else
      Enum.find(state_names, &dispatch_entry_candidate?(workflow, &1))
    end
  end

  defp fallback_dispatch_target_state(issue_state) when is_binary(issue_state) do
    normalized_issue_state = normalize_tracker_state(issue_state)
    ready_state = normalize_tracker_state(Config.settings!().tracker.ready_label)

    if normalized_issue_state != ready_state do
      nil
    else
      active_states()
      |> Enum.find(fn state_name ->
        normalized_state = normalize_tracker_state(state_name)
        normalized_state != ready_state
      end)
    end
  end

  defp dispatch_entry_candidate?(workflow, state_name) do
    case Map.get(workflow, state_name, %{activities: [], transitions: []}) do
      %{activities: activities, transitions: [_ | _]} ->
        Enum.all?(activities, &(not skill_activity?(&1)))

      _ ->
        false
    end
  end

  defp skill_activity?(%Workflow.Activity{type: :skill}), do: true
  defp skill_activity?(_activity), do: false

  defp fallback_initial_dispatch_transition_name do
    with ready_state when is_binary(ready_state) <- Config.settings!().tracker.ready_label,
         target_state when is_binary(target_state) <- fallback_dispatch_target_state(ready_state) do
      SymphonyElixir.DispatchLifecycle.transition_name(ready_state, target_state)
    end
  end

  defp fetch_issue_state(slug, context) do
    case Issue.load_by_slug(
           context.root_path,
           slug,
           context.project.dir,
           context.workflow,
           context.project.runtime
         ) do
      {:ok, issue} ->
        case maybe_apply_transition(issue, context) do
          {:ok, transitioned_issue} -> {:ok, transitioned_issue}
          {:error, _reason} = error -> error
        end

      {:error, {:issue_not_found, ^slug}} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_issue_states(issue_ids, context) when is_list(issue_ids) do
    Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, issues} ->
      issue_id
      |> fetch_issue_state(context)
      |> append_issue_state(issues)
    end)
  end

  defp append_issue_state({:ok, nil}, issues), do: {:cont, {:ok, issues}}
  defp append_issue_state({:ok, issue}, issues), do: {:cont, {:ok, [issue | issues]}}
  defp append_issue_state({:error, _reason} = error, _issues), do: {:halt, error}

  defp apply_transitions(issues, context) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, transitioned_issues} ->
      case maybe_apply_transition(issue, context) do
        {:ok, transitioned_issue} -> {:cont, {:ok, [transitioned_issue | transitioned_issues]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, transitioned_issues} -> {:ok, Enum.reverse(transitioned_issues)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_apply_transition(issue, context) do
    case read_workpad_status(issue.workpad_path) do
      {:ok, workpad_status} ->
        maybe_transition_issue(issue, context, normalize_storage_state(workpad_status))

      :missing ->
        {:ok, issue}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_transition_issue(issue, context, normalized_workpad_status) do
    if is_binary(normalized_workpad_status) and
         normalized_workpad_status != normalize_storage_state(issue.state) do
      transition_for_workpad_status(issue, context, normalized_workpad_status)
    else
      {:ok, issue}
    end
  end

  defp transition_for_workpad_status(issue, context, normalized_workpad_status) do
    case Workflow.first_matching_transition_to(
           context.workflow,
           normalize_storage_state(issue.state),
           normalized_workpad_status,
           issue.issue_path
         ) do
      {:ok, nil} ->
        {:ok, issue}

      {:ok, _transition} ->
        transition_issue(issue, normalized_workpad_status, context)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_transition(nil, issue_state, target_state),
    do: {:error, {:no_declared_transition, issue_state, target_state}}

  defp ensure_transition(_transition, _issue_state, _target_state), do: :ok

  defp fallback_active_states_if_empty([]), do: fallback_active_states()
  defp fallback_active_states_if_empty(active_states), do: active_states

  defp fallback_active_states do
    Config.settings!().tracker.active_states || []
  end

  defp transition_issue(issue, workpad_status, context) do
    with :ok <- move_issue(issue, workpad_status, context.root_path) do
      Issue.load_by_slug(
        context.root_path,
        issue.issue_slug,
        context.project.dir,
        context.workflow,
        context.project.runtime
      )
    end
  end

  defp dispatchable_activity?(issue, workflow) do
    workflow
    |> Map.get(normalize_storage_state(issue.state), %{activities: []})
    |> Map.get(:activities, [])
    |> Enum.any?(fn
      %Workflow.Activity{type: :skill} -> true
      _ -> false
    end)
  end

  defp move_issue(issue, target_state, root_path) do
    Logger.info("Applying local issue transition slug=#{issue.issue_slug} from=#{normalize_storage_state(issue.state)} to=#{target_state}")

    source = current_storage_path(issue)
    target = target_storage_path(root_path, issue.issue_slug, target_state)
    source_state = normalize_storage_state(issue.state)
    source_directory? = MapSet.member?(@directory_states, source_state)
    target_directory? = MapSet.member?(@directory_states, target_state)

    case {source_directory?, target_directory?} do
      {true, true} ->
        target_issue_path = Path.join(target, "issue.md")

        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.rename(source, target) do
          update_frontmatter_status(target_issue_path, target_state)
        end

      {false, true} ->
        target_issue_path = Path.join(target, "issue.md")

        with :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- File.mkdir_p(target),
             :ok <- File.cp(source, target_issue_path),
             :ok <- update_frontmatter_status(target_issue_path, target_state),
             :ok <- File.rm(source),
             :ok <- restore_or_initialize_workpad(issue, target_state, target) do
          restore_ready_artifacts(issue, target)
        end

      {true, false} ->
        collapse_issue_directory(issue, target, target_state)

      {false, false} ->
        {:error, {:unsupported_storage_transition, source_state, target_state}}
    end
  rescue
    error in [File.Error] -> {:error, error}
  end

  defp current_storage_path(issue) do
    if MapSet.member?(@directory_states, normalize_storage_state(issue.state)),
      do: issue.issue_dir,
      else: issue.issue_path
  end

  defp target_storage_path(root_path, slug, state) do
    if MapSet.member?(@directory_states, state) do
      Path.join([root_path, state, slug])
    else
      Path.join([root_path, state, "#{slug}.md"])
    end
  end

  defp ensure_workpad(path, target_state) do
    if File.exists?(path), do: :ok, else: File.write(path, "---\nstatus: #{target_state}\n---\n")
  end

  defp restore_or_initialize_workpad(issue, target_state, target_dir) do
    target_workpad = Path.join(target_dir, "workpad.md")

    if File.exists?(issue.workpad_path) do
      with :ok <- File.rename(issue.workpad_path, target_workpad) do
        update_frontmatter_status(target_workpad, target_state)
      end
    else
      ensure_workpad(target_workpad, target_state)
    end
  end

  defp restore_ready_artifacts(issue, target_dir) do
    source_artifacts_dir = Path.join(Path.dirname(issue.issue_path), "#{issue.issue_slug}.artifacts")

    if File.dir?(source_artifacts_dir) do
      source_artifacts_dir
      |> File.ls!()
      |> move_ready_artifacts(source_artifacts_dir, target_dir)
      |> case do
        :ok -> File.rmdir(source_artifacts_dir)
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp move_ready_artifacts(artifact_names, source_artifacts_dir, target_dir) do
    Enum.reduce_while(artifact_names, :ok, fn artifact_name, :ok ->
      case File.rename(
             Path.join(source_artifacts_dir, artifact_name),
             Path.join(target_dir, artifact_name)
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp copy_artifact_sidecars(issue, target_issue_path) do
    case issue_artifact_files(issue) do
      [] ->
        :ok

      artifact_files ->
        artifacts_dir = Path.join(Path.dirname(target_issue_path), "#{issue.issue_slug}.artifacts")

        with :ok <- File.mkdir_p(artifacts_dir) do
          copy_artifacts(artifact_files, issue.issue_dir, artifacts_dir)
        end
    end
  end

  defp issue_artifact_files(issue) do
    issue.issue_dir
    |> File.ls!()
    |> Enum.reject(&(&1 in ["issue.md", "workpad.md"]))
  end

  defp copy_artifacts(artifact_files, source_dir, target_dir) do
    Enum.reduce_while(artifact_files, :ok, fn file_name, :ok ->
      case File.cp_r(Path.join(source_dir, file_name), Path.join(target_dir, file_name)) do
        {:ok, _paths} -> {:cont, :ok}
        {:error, _reason, _path} = error -> {:halt, error}
      end
    end)
  end

  defp update_frontmatter_status(issue_path, target_state) do
    with {:ok, {frontmatter, body}} <- Issue.read_frontmatter_safe(issue_path) do
      updated =
        frontmatter
        |> Map.put("status", target_state)
        |> dump_frontmatter()

      File.write(issue_path, "---\n#{updated}---\n#{body}\n")
    end
  end

  defp read_workpad_status(path) do
    if File.exists?(path) do
      case Issue.read_frontmatter_safe(path) do
        {:ok, {frontmatter, _body}} -> {:ok, Map.get(frontmatter, "status")}
        {:error, _reason} = error -> error
      end
    else
      :missing
    end
  end

  defp passes_adapter_filters?(issue, adapter_config) when is_map(adapter_config) do
    case Map.get(adapter_config, "filters", %{}) do
      filters when is_map(filters) ->
        passes_state_filter?(issue, filters) and passes_assignee_filter?(issue, filters)

      _ ->
        false
    end
  end

  defp passes_state_filter?(issue, filters) do
    case Map.get(filters, "states") do
      states when is_list(states) ->
        normalized_states =
          states
          |> Enum.map(&normalize_tracker_state/1)
          |> MapSet.new()

        MapSet.member?(normalized_states, normalize_tracker_state(issue.state))

      _ ->
        true
    end
  end

  defp passes_assignee_filter?(issue, filters) do
    case Map.get(filters, "assignee") do
      assignee when is_binary(assignee) and assignee != "" ->
        issue.assignee_id == assignee

      _ ->
        true
    end
  end

  defp dump_frontmatter(frontmatter) when is_map(frontmatter) do
    frontmatter
    |> Enum.map_join("\n", fn {key, value} -> dump_frontmatter_entry(to_string(key), value, 0) end)
    |> Kernel.<>("\n")
  end

  defp dump_frontmatter_entry(key, value, indent) when is_binary(value),
    do: "#{indent(indent)}#{key}: #{dump_yaml_string(value)}"

  defp dump_frontmatter_entry(key, value, indent) when is_integer(value),
    do: "#{indent(indent)}#{key}: #{value}"

  defp dump_frontmatter_entry(key, true, indent), do: "#{indent(indent)}#{key}: true"
  defp dump_frontmatter_entry(key, false, indent), do: "#{indent(indent)}#{key}: false"
  defp dump_frontmatter_entry(key, nil, indent), do: "#{indent(indent)}#{key}:"

  defp dump_frontmatter_entry(key, values, indent) when is_list(values) do
    if values == [] do
      "#{indent(indent)}#{key}: []"
    else
      items = Enum.map_join(values, "\n", &dump_yaml_list_item(&1, indent + 2))
      "#{indent(indent)}#{key}:\n#{items}"
    end
  end

  defp dump_frontmatter_entry(key, values, indent) when is_map(values) do
    if map_size(values) == 0 do
      "#{indent(indent)}#{key}: {}"
    else
      entries = dump_map_entries(values, indent + 2)
      "#{indent(indent)}#{key}:\n#{entries}"
    end
  end

  defp dump_frontmatter_entry(key, value, indent),
    do: "#{indent(indent)}#{key}: #{dump_yaml_scalar(value)}"

  defp dump_map_entries(values, indent) when is_map(values) do
    values
    |> Enum.map_join("\n", fn {key, value} -> dump_frontmatter_entry(to_string(key), value, indent) end)
  end

  defp dump_yaml_list_item(value, indent) when is_list(value) do
    prefix = "#{indent(indent)}-"

    if value == [] do
      "#{prefix} []"
    else
      "#{prefix}\n#{Enum.map_join(value, "\n", &dump_yaml_list_item(&1, indent + 2))}"
    end
  end

  defp dump_yaml_list_item(value, indent) when is_map(value) do
    prefix = "#{indent(indent)}-"

    if map_size(value) == 0 do
      "#{prefix} {}"
    else
      "#{prefix}\n#{dump_map_entries(value, indent + 2)}"
    end
  end

  defp dump_yaml_list_item(value, indent),
    do: "#{indent(indent)}- #{dump_yaml_scalar(value)}"

  defp dump_yaml_scalar(value) when is_binary(value), do: dump_yaml_string(value)
  defp dump_yaml_scalar(value) when is_integer(value), do: to_string(value)
  defp dump_yaml_scalar(true), do: "true"
  defp dump_yaml_scalar(false), do: "false"
  defp dump_yaml_scalar(nil), do: "null"
  defp dump_yaml_scalar(value), do: dump_yaml_string(inspect(value))

  defp indent(size), do: String.duplicate(" ", size)

  defp dump_yaml_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp collapse_issue_directory(issue, target_issue_path, target_state) do
    with :ok <- File.mkdir_p(Path.dirname(target_issue_path)),
         :ok <- File.cp(issue.issue_path, target_issue_path),
         :ok <- update_frontmatter_status(target_issue_path, target_state),
         :ok <- copy_workpad_sidecar(issue, target_issue_path),
         :ok <- copy_artifact_sidecars(issue, target_issue_path),
         {:ok, _removed} <- File.rm_rf(issue.issue_dir) do
      :ok
    end
  end

  defp copy_workpad_sidecar(issue, target_issue_path) do
    workpad_target = Path.join(Path.dirname(target_issue_path), "#{issue.issue_slug}.workpad.md")

    if File.exists?(issue.workpad_path), do: File.cp(issue.workpad_path, workpad_target), else: :ok
  end

  defp normalize_storage_state(state_name), do: Issue.storage_state_from_tracker_state(state_name)
  defp normalize_tracker_state(nil), do: nil
  defp normalize_tracker_state("status:" <> _ = state_name), do: state_name

  defp normalize_tracker_state(state_name) when is_binary(state_name),
    do: Issue.tracker_state_from_storage_state(state_name)
end
