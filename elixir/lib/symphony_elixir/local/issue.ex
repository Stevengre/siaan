defmodule SymphonyElixir.Local.Issue do
  @moduledoc """
  Reads local issue directories and materializes orchestrator issue structs.
  """

  alias SymphonyElixir.Linear.Issue, as: TrackerIssue
  alias SymphonyElixir.Local.Workflow

  @directory_states MapSet.new(["in-progress", "review", "done"])

  @spec storage_state_from_tracker_state(String.t() | nil) :: String.t() | nil
  def storage_state_from_tracker_state("status:" <> state_name), do: state_name
  def storage_state_from_tracker_state(state_name) when is_binary(state_name), do: state_name
  def storage_state_from_tracker_state(_state_name), do: nil

  @spec tracker_state_from_storage_state(String.t()) :: String.t()
  def tracker_state_from_storage_state(state_name) when is_binary(state_name),
    do: "status:#{state_name}"

  @spec scan_root(Path.t(), Path.t(), map(), String.t() | nil) ::
          {:ok, [TrackerIssue.t()]} | {:error, term()}
  def scan_root(root_path, project_dir, workflow, project_runtime \\ nil)
      when is_binary(root_path) and is_binary(project_dir) do
    states = workflow_states(root_path, workflow)

    Enum.reduce_while(states, {:ok, []}, fn state, {:ok, issues} ->
      case scan_state(root_path, state, project_dir, workflow, project_runtime) do
        {:ok, state_issues} -> {:cont, {:ok, issues ++ state_issues}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  rescue
    error in [File.Error] -> {:error, error}
  end

  @spec load_by_slug(Path.t(), String.t(), Path.t(), map(), String.t() | nil) ::
          {:ok, TrackerIssue.t()} | {:error, term()}
  def load_by_slug(root_path, slug, project_dir, workflow, project_runtime \\ nil)
      when is_binary(root_path) and is_binary(slug) and is_binary(project_dir) do
    states = workflow_states(root_path, workflow)

    Enum.reduce_while(states, {:error, {:issue_not_found, slug}}, fn state, _acc ->
      case load_slug_from_state(state, root_path, slug, project_dir, workflow, project_runtime) do
        {:ok, issue} -> {:halt, {:ok, issue}}
        :skip -> {:cont, {:error, {:issue_not_found, slug}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  rescue
    error in [File.Error] -> {:error, error}
  end

  defp load_slug_from_state(state, root_path, slug, project_dir, workflow, project_runtime) do
    path = issue_path_for_state(root_path, state, slug)

    if issue_document_path?(state, path) and File.exists?(path) do
      build_issue(root_path, state, slug, path, project_dir, workflow, project_runtime)
    else
      :skip
    end
  end

  defp scan_state(root_path, state, project_dir, workflow, project_runtime) do
    state_path = Path.join(root_path, state)

    entries =
      if MapSet.member?(@directory_states, state) do
        state_path
        |> File.ls!()
        |> Enum.filter(&File.exists?(Path.join([state_path, &1, "issue.md"])))
        |> Enum.map(fn slug ->
          {slug, Path.join([state_path, slug, "issue.md"])}
        end)
      else
        state_path
        |> File.ls!()
        |> Enum.filter(&issue_document_file?/1)
        |> Enum.map(fn file_name ->
          {Path.rootname(file_name), Path.join(state_path, file_name)}
        end)
      end

    Enum.reduce_while(entries, {:ok, []}, fn {slug, issue_path}, {:ok, issues} ->
      case build_issue(root_path, state, slug, issue_path, project_dir, workflow, project_runtime) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, _reason} = error -> error
    end
  end

  defp build_issue(root_path, state, slug, issue_path, project_dir, workflow, project_runtime) do
    with {:ok, {frontmatter, body}} <- read_frontmatter_safe(issue_path) do
      issue_dir = Path.dirname(issue_path)

      workpad_path =
        if(MapSet.member?(@directory_states, state),
          do: Path.join(issue_dir, "workpad.md"),
          else: Path.join(issue_dir, "#{slug}.workpad.md")
        )

      skill_template =
        workflow
        |> Map.get(state, %{activities: []})
        |> Map.get(:activities, [])
        |> Enum.find_value(fn
          %Workflow.Activity{type: :skill, name: "siaan-inprogress"} ->
            skill_template_path("siaan-inprogress.md")

          _ ->
            nil
        end)

      {:ok,
       %TrackerIssue{
         id: slug,
         identifier: Map.get(frontmatter, "identifier", slug),
         title: Map.get(frontmatter, "title", slug),
         description: body,
         state: tracker_state_from_storage_state(state),
         url: Map.get(frontmatter, "url"),
         labels: List.wrap(Map.get(frontmatter, "labels", [])),
         assignee_id: Map.get(frontmatter, "assignee"),
         branch_name: Map.get(frontmatter, "current-branch"),
         issue_root: root_path,
         issue_slug: slug,
         issue_path: issue_path,
         issue_dir: issue_dir,
         workpad_path: workpad_path,
         project_dir: project_dir,
         project_runtime: project_runtime,
         prompt_template_path: skill_template,
         base_branch: Map.get(frontmatter, "base-branch"),
         current_branch: Map.get(frontmatter, "current-branch")
       }}
    end
  end

  defp issue_path_for_state(root_path, state, slug) do
    if MapSet.member?(@directory_states, state) do
      Path.join([root_path, state, slug, "issue.md"])
    else
      Path.join([root_path, state, "#{slug}.md"])
    end
  end

  defp workflow_states(root_path, workflow) when is_map(workflow) do
    workflow
    |> Map.keys()
    |> Enum.filter(&File.dir?(Path.join(root_path, &1)))
  end

  defp issue_document_path?(state, path) when is_binary(state) and is_binary(path) do
    MapSet.member?(@directory_states, state) or issue_document_file?(Path.basename(path))
  end

  defp issue_document_file?(file_name) when is_binary(file_name) do
    String.ends_with?(file_name, ".md") and not String.ends_with?(file_name, ".workpad.md")
  end

  defp skill_template_path(file_name) when is_binary(file_name) do
    case :code.priv_dir(:symphony_elixir) do
      priv_dir when is_list(priv_dir) ->
        path = Path.join([List.to_string(priv_dir), "skills", file_name])
        if File.exists?(path), do: path, else: nil

      _ ->
        nil
    end
  end

  @spec read_frontmatter(Path.t()) :: {map(), String.t()}
  def read_frontmatter(path) when is_binary(path) do
    case read_frontmatter_safe(path) do
      {:ok, result} -> result
      {:error, reason} -> raise "failed to read frontmatter for #{path}: #{inspect(reason)}"
    end
  end

  @spec read_frontmatter_safe(Path.t()) :: {:ok, {map(), String.t()}} | {:error, term()}
  def read_frontmatter_safe(path) when is_binary(path) do
    {:ok, contents} = File.read(path)
    lines = String.split(contents, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {frontmatter_lines, rest} = Enum.split_while(tail, &(&1 != "---"))

        frontmatter =
          case rest do
            ["---" | _body_lines] ->
              frontmatter_lines
              |> Enum.join("\n")
              |> YamlElixir.read_from_string!()

            _ ->
              %{}
          end

        body =
          case rest do
            ["---" | body_lines] -> Enum.join(body_lines, "\n") |> String.trim()
            _ -> contents |> String.trim()
          end

        {:ok, {frontmatter || %{}, body}}

      _ ->
        {:ok, {%{}, String.trim(contents)}}
    end
  rescue
    error in [File.Error] ->
      {:error, error}

    error ->
      {:error, {:invalid_frontmatter, path, Exception.message(error)}}
  end
end
