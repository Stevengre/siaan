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

  @spec scan_root(Path.t(), Path.t(), map()) :: {:ok, [TrackerIssue.t()]} | {:error, term()}
  def scan_root(root_path, project_dir, workflow)
      when is_binary(root_path) and is_binary(project_dir) do
    states =
      root_path
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(root_path, &1)))

    issues =
      Enum.flat_map(states, fn state ->
        scan_state(root_path, state, project_dir, workflow)
      end)

    {:ok, issues}
  rescue
    error in [File.Error] -> {:error, error}
  end

  @spec load_by_slug(Path.t(), String.t(), Path.t(), map()) ::
          {:ok, TrackerIssue.t()} | {:error, term()}
  def load_by_slug(root_path, slug, project_dir, workflow)
      when is_binary(root_path) and is_binary(slug) and is_binary(project_dir) do
    states =
      root_path
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(root_path, &1)))

    case Enum.find_value(states, &load_slug_from_state(&1, root_path, slug, project_dir, workflow)) do
      {:ok, issue} -> {:ok, issue}
      nil -> {:error, {:issue_not_found, slug}}
    end
  rescue
    error in [File.Error] -> {:error, error}
  end

  defp load_slug_from_state(state, root_path, slug, project_dir, workflow) do
    path = issue_path_for_state(root_path, state, slug)
    if File.exists?(path), do: {:ok, build_issue(root_path, state, slug, path, project_dir, workflow)}
  end

  defp scan_state(root_path, state, project_dir, workflow) do
    state_path = Path.join(root_path, state)

    if MapSet.member?(@directory_states, state) do
      state_path
      |> File.ls!()
      |> Enum.filter(&File.exists?(Path.join([state_path, &1, "issue.md"])))
      |> Enum.map(fn slug ->
        issue_path = Path.join([state_path, slug, "issue.md"])
        build_issue(root_path, state, slug, issue_path, project_dir, workflow)
      end)
    else
      state_path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn file_name ->
        slug = Path.rootname(file_name)
        issue_path = Path.join(state_path, file_name)
        build_issue(root_path, state, slug, issue_path, project_dir, workflow)
      end)
    end
  end

  defp build_issue(root_path, state, slug, issue_path, project_dir, workflow) do
    {frontmatter, body} = read_frontmatter(issue_path)
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
          Path.join(project_dir, "elixir/priv/skills/siaan-inprogress.md")

        _ ->
          nil
      end)

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
      prompt_template_path: skill_template,
      base_branch: Map.get(frontmatter, "base-branch"),
      current_branch: Map.get(frontmatter, "current-branch")
    }
  end

  defp issue_path_for_state(root_path, state, slug) do
    if MapSet.member?(@directory_states, state) do
      Path.join([root_path, state, slug, "issue.md"])
    else
      Path.join([root_path, state, "#{slug}.md"])
    end
  end

  @spec read_frontmatter(Path.t()) :: {map(), String.t()}
  def read_frontmatter(path) when is_binary(path) do
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

        {frontmatter || %{}, body}

      _ ->
        {%{}, String.trim(contents)}
    end
  end
end
