defmodule SymphonyElixir.Local.Adapter do
  @moduledoc """
  Local-file-backed tracker adapter used by the orchestrator.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Local.{Issue, ProjectConfig, Workflow}

  @directory_states MapSet.new(["in-progress", "review", "done"])

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, context} <- load_context(),
         {:ok, issues} <-
           Issue.scan_root(context.root_path, context.project.dir, context.workflow) do
      active_states =
        Config.settings!().tracker.active_states
        |> Enum.map(&normalize_tracker_state/1)
        |> MapSet.new()

      issues
      |> Enum.filter(&passes_adapter_filters?(&1, context.project.adapter))
      |> Enum.map(&maybe_apply_transition(&1, context))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, issue} -> issue end)
      |> Enum.filter(
        &(MapSet.member?(active_states, normalize_tracker_state(&1.state)) and
            dispatchable_activity?(&1, context.workflow))
      )
      |> then(&{:ok, &1})
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
           Issue.scan_root(context.root_path, context.project.dir, context.workflow) do
      issues
      |> Enum.filter(&passes_adapter_filters?(&1, context.project.adapter))
      |> Enum.map(&maybe_apply_transition(&1, context))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, issue} -> issue end)
      |> Enum.filter(&MapSet.member?(wanted, normalize_tracker_state(&1.state)))
      |> then(&{:ok, &1})
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    with {:ok, context} <- load_context() do
      issues = Enum.flat_map(issue_ids, &fetch_issue_state(&1, context))

      {:ok, issues}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: :ok

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, target_state) do
    normalized_target = normalize_storage_state(target_state)

    with {:ok, context} <- load_context(),
         {:ok, issue} <-
           Issue.load_by_slug(context.root_path, issue_id, context.project.dir, context.workflow),
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

  defp fetch_issue_state(slug, context) do
    case Issue.load_by_slug(context.root_path, slug, context.project.dir, context.workflow) do
      {:ok, issue} ->
        case maybe_apply_transition(issue, context) do
          {:ok, transitioned_issue} -> [transitioned_issue]
          _ -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp maybe_apply_transition(issue, context) do
    workpad_status =
      issue.workpad_path
      |> read_workpad_status()
      |> normalize_storage_state()

    if is_binary(workpad_status) and workpad_status != normalize_storage_state(issue.state) do
      case Workflow.first_matching_transition_to(
             context.workflow,
             normalize_storage_state(issue.state),
             workpad_status,
             issue.issue_path
           ) do
        {:ok, nil} ->
          {:ok, issue}

        {:ok, _transition} ->
          transition_issue(issue, workpad_status, context)

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, issue}
    end
  end

  defp ensure_transition(nil, issue_state, target_state),
    do: {:error, {:no_declared_transition, issue_state, target_state}}

  defp ensure_transition(_transition, _issue_state, _target_state), do: :ok

  defp transition_issue(issue, workpad_status, context) do
    with :ok <- move_issue(issue, workpad_status, context.root_path) do
      Issue.load_by_slug(
        context.root_path,
        issue.issue_slug,
        context.project.dir,
        context.workflow
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
        update_frontmatter_status!(issue.issue_path, target_state)
        File.mkdir_p!(Path.dirname(target))
        File.rename(source, target)

      {false, true} ->
        File.mkdir_p!(Path.dirname(target))
        File.mkdir_p!(target)
        target_issue_path = Path.join(target, "issue.md")
        File.cp!(source, target_issue_path)
        update_frontmatter_status!(target_issue_path, target_state)
        File.rm!(source)
        restore_or_initialize_workpad(issue, target_state, target)
        restore_ready_artifacts(issue, target)
        :ok

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
    if File.exists?(path), do: :ok, else: File.write!(path, "---\nstatus: #{target_state}\n---\n")
  end

  defp restore_or_initialize_workpad(issue, target_state, target_dir) do
    target_workpad = Path.join(target_dir, "workpad.md")

    if File.exists?(issue.workpad_path) do
      File.rename!(issue.workpad_path, target_workpad)
    else
      ensure_workpad(target_workpad, target_state)
    end
  end

  defp restore_ready_artifacts(issue, target_dir) do
    source_artifacts_dir = Path.join(Path.dirname(issue.issue_path), "#{issue.issue_slug}.artifacts")

    if File.dir?(source_artifacts_dir) do
      source_artifacts_dir
      |> File.ls!()
      |> Enum.each(fn artifact_name ->
        File.rename!(
          Path.join(source_artifacts_dir, artifact_name),
          Path.join(target_dir, artifact_name)
        )
      end)

      File.rmdir!(source_artifacts_dir)
    end
  end

  defp collapse_issue_directory(issue, target_issue_path, target_state) do
    File.mkdir_p!(Path.dirname(target_issue_path))
    File.cp!(issue.issue_path, target_issue_path)
    update_frontmatter_status!(target_issue_path, target_state)

    workpad_target = Path.join(Path.dirname(target_issue_path), "#{issue.issue_slug}.workpad.md")

    if File.exists?(issue.workpad_path) do
      File.cp!(issue.workpad_path, workpad_target)
    end

    artifact_files =
      issue.issue_dir
      |> File.ls!()
      |> Enum.reject(&(&1 in ["issue.md", "workpad.md"]))

    if artifact_files != [] do
      artifacts_dir = Path.join(Path.dirname(target_issue_path), "#{issue.issue_slug}.artifacts")
      File.mkdir_p!(artifacts_dir)

      Enum.each(artifact_files, fn file_name ->
        File.cp_r!(Path.join(issue.issue_dir, file_name), Path.join(artifacts_dir, file_name))
      end)
    end

    File.rm_rf!(issue.issue_dir)
    :ok
  end

  defp update_frontmatter_status!(issue_path, target_state) do
    {frontmatter, body} = Issue.read_frontmatter(issue_path)

    updated =
      frontmatter
      |> Map.put("status", target_state)
      |> dump_frontmatter()

    File.write!(issue_path, "---\n#{updated}---\n#{body}\n")
  end

  defp dump_frontmatter(frontmatter) when is_map(frontmatter) do
    frontmatter
    |> Enum.map_join("\n", fn {key, value} -> dump_frontmatter_entry(to_string(key), value) end)
    |> Kernel.<>("\n")
  end

  defp dump_frontmatter_entry(key, value) when is_binary(value), do: "#{key}: #{dump_yaml_string(value)}"
  defp dump_frontmatter_entry(key, value) when is_integer(value), do: "#{key}: #{value}"
  defp dump_frontmatter_entry(key, true), do: "#{key}: true"
  defp dump_frontmatter_entry(key, false), do: "#{key}: false"
  defp dump_frontmatter_entry(key, nil), do: "#{key}:"

  defp dump_frontmatter_entry(key, values) when is_list(values) do
    items = Enum.map_join(values, "\n", &"  - #{dump_yaml_value(&1)}")
    "#{key}:\n#{items}"
  end

  defp dump_frontmatter_entry(key, value), do: "#{key}: #{dump_yaml_value(value)}"

  defp dump_yaml_value(value) when is_binary(value), do: dump_yaml_string(value)
  defp dump_yaml_value(value) when is_integer(value), do: to_string(value)
  defp dump_yaml_value(true), do: "true"
  defp dump_yaml_value(false), do: "false"
  defp dump_yaml_value(nil), do: "null"
  defp dump_yaml_value(value), do: dump_yaml_string(inspect(value))

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

  defp read_workpad_status(path) do
    if File.exists?(path) do
      {frontmatter, _body} = Issue.read_frontmatter(path)
      Map.get(frontmatter, "status")
    end
  end

  defp passes_adapter_filters?(issue, adapter_config) when is_map(adapter_config) do
    filters = Map.get(adapter_config, "filters", %{})
    passes_state_filter?(issue, filters) and passes_assignee_filter?(issue, filters)
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

  defp normalize_storage_state(state_name), do: Issue.storage_state_from_tracker_state(state_name)
  defp normalize_tracker_state(nil), do: nil
  defp normalize_tracker_state("status:" <> _ = state_name), do: state_name

  defp normalize_tracker_state(state_name) when is_binary(state_name),
    do: Issue.tracker_state_from_storage_state(state_name)
end
