defmodule SymphonyElixir.LocalTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Local.{Adapter, ProjectConfig}
  alias SymphonyElixir.Local.Issue, as: LocalIssue
  alias SymphonyElixir.Local.Workflow, as: LocalWorkflow

  test "project config parses project settings and adapter filters" do
    root = tmp_dir!("local-project-config")
    config_path = Path.join(root, "config.toml")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{Path.expand("..", File.cwd!())}"
      workflow = "workflow.yaml"
      runtime = "local"

      [projects.siaan.adapter]
      type = "github"
      repo = "Stevengre/siaan"
      filters = { assignee = "Stevengre", states = ["status:ready", "status:in-progress"] }
      """
    )

    assert {:ok, project} = ProjectConfig.load(config_path, "siaan")
    assert project.runtime == "local"
    assert project.adapter["type"] == "github"
    assert project.adapter["repo"] == "Stevengre/siaan"
    assert project.adapter["filters"]["assignee"] == "Stevengre"
    assert project.adapter["filters"]["states"] == ["status:ready", "status:in-progress"]
    assert project.workflow == Path.join(root, "workflow.yaml")
  end

  test "project config resolves workflow relative to project dir when the file exists there" do
    root = tmp_dir!("local-project-config-project-root")
    project_dir = Path.join(root, "repo")
    config_path = Path.join(root, "config.toml")

    File.mkdir_p!(Path.join(project_dir, ".claude"))
    File.write!(Path.join(project_dir, ".claude/workflow.yaml"), "ready: {}\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = ".claude/workflow.yaml"
      runtime = "local"

      [projects.siaan.adapter]
      enabled = true
      retries = 3
      """
    )

    assert {:ok, project} = ProjectConfig.load(config_path, "siaan")
    assert project.workflow == Path.join(project_dir, ".claude/workflow.yaml")
    assert project.adapter["enabled"] == true
    assert project.adapter["retries"] == 3
  end

  test "project config resolves relative dir and workflow paths from the config directory" do
    root = tmp_dir!("local-project-config-relative-root")
    project_dir = Path.join(root, "repo")
    config_path = Path.join(root, "config.toml")

    File.mkdir_p!(Path.join(project_dir, ".claude"))
    File.write!(Path.join(project_dir, ".claude/workflow.yaml"), "ready: {}\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "repo"
      workflow = ".claude/workflow.yaml"
      runtime = "local"
      """
    )

    assert {:ok, project} = ProjectConfig.load(config_path, "siaan")
    assert project.dir == project_dir
    assert project.workflow == Path.join(project_dir, ".claude/workflow.yaml")
  end

  test "project config defaults missing runtime to local" do
    root = tmp_dir!("local-project-config-default-runtime")
    project_dir = Path.join(root, "repo")
    config_path = Path.join(root, "config.toml")

    File.mkdir_p!(Path.join(project_dir, ".claude"))
    File.write!(Path.join(project_dir, ".claude/workflow.yaml"), "ready: {}\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = ".claude/workflow.yaml"
      """
    )

    assert {:ok, project} = ProjectConfig.load(config_path, "siaan")
    assert project.runtime == "local"
  end

  test "project config preserves # characters inside quoted values" do
    root = tmp_dir!("local-project-config-hash-values")
    project_dir = Path.join(root, "repo#exp")
    config_path = Path.join(root, "config.toml")

    File.mkdir_p!(Path.join(project_dir, ".claude"))
    File.write!(Path.join(project_dir, ".claude/workflow#1.yaml"), "ready: {}\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "repo#exp"
      workflow = ".claude/workflow#1.yaml"
      runtime = "local"
      """
    )

    assert {:ok, project} = ProjectConfig.load(config_path, "siaan")
    assert project.dir == project_dir
    assert project.workflow == Path.join(project_dir, ".claude/workflow#1.yaml")
  end

  test "project config returns errors for missing projects and invalid assignments" do
    root = tmp_dir!("local-project-config-errors")
    config_path = Path.join(root, "config.toml")

    File.write!(config_path, "[projects.other]\ndir = \"/tmp\"\n")
    assert {:error, {:missing_project, "siaan"}} = ProjectConfig.load(config_path, "siaan")

    File.write!(config_path, "[projects.siaan]\ndir = \"/tmp\"\n")

    assert {:error, {:missing_project_field, "siaan", "workflow"}} =
             ProjectConfig.load(config_path, "siaan")

    File.write!(config_path, "[projects.siaan]\nworkflow = \"workflow.yaml\"\n")

    assert {:error, {:missing_project_field, "siaan", "dir"}} =
             ProjectConfig.load(config_path, "siaan")

    File.write!(config_path, "[projects.siaan]\ninvalid-line\n")

    assert {:error, {:invalid_toml, 2, :invalid_assignment}} =
             ProjectConfig.load(config_path, "siaan")
  end

  test "project config rejects non-map adapter and filters values" do
    root = tmp_dir!("local-project-config-adapter-shape")
    project_dir = Path.join(root, "repo")
    config_path = Path.join(root, "config.toml")

    File.mkdir_p!(Path.join(project_dir, ".claude"))
    File.write!(Path.join(project_dir, ".claude/workflow.yaml"), "ready: {}\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = ".claude/workflow.yaml"
      adapter = "github"
      """
    )

    assert {:error, {:invalid_project_field_type, "siaan", "adapter", :map, "github"}} =
             ProjectConfig.load(config_path, "siaan")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = ".claude/workflow.yaml"

      [projects.siaan.adapter]
      filters = "status:ready"
      """
    )

    assert {:error, {:invalid_project_field_type, "siaan", "adapter.filters", :map, "status:ready"}} =
             ProjectConfig.load(config_path, "siaan")
  end

  test "workflow transition evaluation uses AND within a transition, OR across transitions, and first-match order" do
    workflow = %{
      "in-progress" => %{
        activities: [],
        transitions: [
          %LocalWorkflow.Transition{to: "review", when: ["check-a", "check-b"]},
          %LocalWorkflow.Transition{to: "review", when: ["check-c", "check-d"]}
        ]
      }
    }

    runner = fn
      "check-a", _issue_path -> {:ok, 0}
      "check-b", _issue_path -> {:ok, 1}
      "check-c", _issue_path -> {:ok, 0}
      "check-d", _issue_path -> {:ok, 0}
    end

    assert {:ok, %LocalWorkflow.Transition{when: ["check-c", "check-d"]}} =
             LocalWorkflow.first_matching_transition_to(
               workflow,
               "in-progress",
               "review",
               "/tmp/issue.md",
               runner: runner
             )

    ordered_runner = fn
      "check-a", _issue_path -> {:ok, 0}
      "check-b", _issue_path -> {:ok, 0}
      "check-c", _issue_path -> {:ok, 0}
      "check-d", _issue_path -> {:ok, 0}
    end

    assert {:ok, %LocalWorkflow.Transition{when: ["check-a", "check-b"]}} =
             LocalWorkflow.first_matching_transition_to(
               workflow,
               "in-progress",
               "review",
               "/tmp/issue.md",
               runner: ordered_runner
             )
  end

  test "workflow load and transition evaluation cover missing and failing branches" do
    workflow_root = tmp_dir!("local-workflow-errors")
    workflow_path = Path.join(workflow_root, "workflow.yaml")

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - check: local-check
            interval: 5m
        transitions:
          - to: review
            when:
              - fail-check
      """
    )

    assert {:ok, workflow} = LocalWorkflow.load(workflow_path)

    assert %LocalWorkflow.Activity{type: :check, name: "local-check", interval: "5m"} =
             workflow["in-progress"].activities |> List.first()

    assert {:ok, nil} =
             LocalWorkflow.first_matching_transition(workflow, "review", "/tmp/issue.md")

    assert {:ok, nil} =
             LocalWorkflow.first_matching_transition_to(
               workflow,
               "in-progress",
               "review",
               "/tmp/issue.md",
               runner: fn "fail-check", _issue_path -> {:ok, 1} end
             )

    assert {:error, :boom} =
             LocalWorkflow.first_matching_transition_to(
               workflow,
               "in-progress",
               "review",
               "/tmp/issue.md",
               runner: fn "fail-check", _issue_path -> {:error, :boom} end
             )

    assert {:error, :enoent} = LocalWorkflow.load(Path.join(workflow_root, "missing.yaml"))

    File.write!(workflow_path, "- not-a-map\n")
    assert {:error, :workflow_not_a_map} = LocalWorkflow.load(workflow_path)

    File.write!(workflow_path, "ready:\n")
    assert {:error, {:invalid_state_config, "ready", nil}} = LocalWorkflow.load(workflow_path)

    File.write!(workflow_path, "ready:\n  activities:\n  transitions:\n")

    assert {:error, {:invalid_state_list, "ready", "activities", nil}} =
             LocalWorkflow.load(workflow_path)

    File.write!(workflow_path, "ready:\n  activities:\n    - skll: typo\n")
    assert {:error, {:invalid_activity, %{"skll" => "typo"}}} = LocalWorkflow.load(workflow_path)

    File.write!(workflow_path, "ready:\n  transitions:\n    - to: review\n      when:\n")

    assert {:error, {:invalid_transition_conditions, "review", nil}} =
             LocalWorkflow.load(workflow_path)
  end

  test "local adapter transitions an in-progress issue to review from workpad intent when conditions pass" do
    issue_root = tmp_dir!("local-issue-root")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "orchestrator-local-first"
    issue_dir = Path.join([issue_root, "in-progress", slug])
    pass_script = Path.join(issue_root, "pass-check.sh")

    File.mkdir_p!(issue_dir)

    File.write!(pass_script, "#!/bin/sh\nexit 0\n")
    File.chmod!(pass_script, 0o755)

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
            when:
              - #{pass_script}
      review:
        activities: []
        transitions: []
      """
    )

    File.write!(
      Path.join(issue_dir, "issue.md"),
      """
      ---
      title: Orchestrator local-first
      status: in-progress
      current-branch: feature/local-first
      ---
      Issue body
      """
    )

    File.write!(
      Path.join(issue_dir, "workpad.md"),
      """
      ---
      status: review
      ---
      Ready for review
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["ready", "in-progress"],
      tracker_terminal_states: ["done"]
    )

    assert {:ok, []} = Adapter.fetch_candidate_issues()
    assert File.exists?(Path.join([issue_root, "review", slug, "issue.md"]))
    refute File.exists?(Path.join([issue_root, "in-progress", slug, "issue.md"]))

    assert {:ok, [issue]} = Adapter.fetch_issue_states_by_ids([slug])
    assert issue.state == "status:review"
  end

  test "local adapter surfaces directory transition rename failures without rewriting source status" do
    issue_root = tmp_dir!("local-transition-rename-failure")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "rename-failure"
    issue_dir = Path.join([issue_root, "in-progress", slug])
    blocked_target = Path.join([issue_root, "review", slug])

    File.mkdir_p!(issue_dir)
    File.mkdir_p!(blocked_target)
    File.write!(Path.join(blocked_target, "issue.md"), "occupied\n")

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
      review:
        activities: []
        transitions: []
      """
    )

    File.write!(
      Path.join(issue_dir, "issue.md"),
      """
      ---
      title: Rename failure
      status: in-progress
      ---
      Issue body
      """
    )

    File.write!(Path.join(issue_dir, "workpad.md"), "---\nstatus: review\n---\n")

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["in-progress"],
      tracker_terminal_states: ["done"]
    )

    assert {:error, reason} = Adapter.fetch_candidate_issues()
    assert reason in [:eexist, :enotempty]
    assert File.exists?(Path.join(issue_dir, "issue.md"))
    refute File.read!(Path.join(issue_dir, "issue.md")) =~ "status: review"
  end

  test "local adapter ignores states without dispatchable activities" do
    issue_root = tmp_dir!("local-ignored-state")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())

    File.mkdir_p!(Path.join(issue_root, "triage"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join([issue_root, "triage", "draft.md"]),
      """
      ---
      title: Draft
      status: triage
      ---
      Draft body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["triage", "in-progress"],
      tracker_terminal_states: ["done"]
    )

    assert {:ok, []} = Adapter.fetch_candidate_issues()
  end

  test "local issue helpers cover missing files and frontmatter fallbacks" do
    issue_root = tmp_dir!("local-issue-helper-coverage")
    project_dir = Path.expand("..", File.cwd!())
    workflow = %{"ready" => %{activities: [], transitions: []}}

    File.mkdir_p!(Path.join(issue_root, "ready"))
    File.write!(Path.join(issue_root, "ready/plain.md"), "plain body\n")

    assert {:ok, [issue]} = LocalIssue.scan_root(issue_root, project_dir, workflow)
    assert issue.id == "plain"
    assert issue.workpad_path == Path.join(issue_root, "ready/plain.workpad.md")
    assert issue.prompt_template_path == nil

    assert {:error, {:issue_not_found, "missing"}} =
             LocalIssue.load_by_slug(issue_root, "missing", project_dir, workflow)

    assert {%{}, "plain body"} =
             LocalIssue.read_frontmatter(Path.join(issue_root, "ready/plain.md"))

    File.write!(
      Path.join(issue_root, "ready/bad.md"),
      """
      ---
      title: [unterminated
      ---
      broken
      """
    )

    assert {:error, {:invalid_frontmatter, _, _}} =
             LocalIssue.read_frontmatter_safe(Path.join(issue_root, "ready/bad.md"))
  end

  test "local issue helpers preserve project runtime metadata on loaded issues" do
    issue_root = tmp_dir!("local-issue-runtime")
    project_dir = Path.join(issue_root, "repo")
    workflow = %{"in-progress" => %{activities: [], transitions: []}}
    slug = "runtime-aware-issue"

    File.mkdir_p!(Path.join([issue_root, "in-progress", slug]))
    File.mkdir_p!(project_dir)

    File.write!(
      Path.join([issue_root, "in-progress", slug, "issue.md"]),
      """
      ---
      identifier: GH-42
      title: Runtime-aware issue
      status: in-progress
      ---
      body
      """
    )

    File.write!(
      Path.join([issue_root, "in-progress", slug, "workpad.md"]),
      """
      ---
      status: in-progress
      ---
      """
    )

    assert {:ok, issue} =
             LocalIssue.load_by_slug(issue_root, slug, project_dir, workflow, "local")

    assert issue.project_dir == project_dir
    assert issue.project_runtime == "local"
  end

  test "local issue scan ignores collapsed workpad sidecars in file states" do
    issue_root = tmp_dir!("local-issue-sidecar-scan")
    project_dir = Path.expand("..", File.cwd!())
    workflow = %{"ready" => %{activities: [], transitions: []}}

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      Path.join(issue_root, "ready/plain.md"),
      """
      ---
      title: Plain issue
      status: ready
      ---
      plain body
      """
    )

    File.write!(
      Path.join(issue_root, "ready/plain.workpad.md"),
      """
      ---
      status: in-progress
      ---
      sidecar body
      """
    )

    assert {:ok, [issue]} = LocalIssue.scan_root(issue_root, project_dir, workflow)
    assert issue.id == "plain"

    assert {:error, {:issue_not_found, "plain.workpad"}} =
             LocalIssue.load_by_slug(issue_root, "plain.workpad", project_dir, workflow)
  end

  test "local issue scan ignores sibling directories that are not workflow states" do
    issue_root = tmp_dir!("local-scan-states-only")
    project_dir = Path.join(issue_root, "repo")
    workflow = %{"ready" => %{activities: [], transitions: []}}

    File.mkdir_p!(Path.join(issue_root, "ready"))
    File.mkdir_p!(project_dir)

    File.write!(
      Path.join([issue_root, "ready", "queued.md"]),
      """
      ---
      title: Queued
      status: ready
      ---
      queued body
      """
    )

    File.write!(
      Path.join(project_dir, "README.md"),
      """
      ---
      title: [unterminated
      ---
      """
    )

    assert {:ok, [issue]} = LocalIssue.scan_root(issue_root, project_dir, workflow)
    assert issue.id == "queued"

    assert {:ok, same_issue} = LocalIssue.load_by_slug(issue_root, "queued", project_dir, workflow)
    assert same_issue.id == "queued"
  end

  test "local adapter filters candidate issues by adapter assignee and states" do
    issue_root = tmp_dir!("local-filtered-state")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"

      [projects.siaan.adapter]
      filters = { assignee = "Stevengre", states = ["status:ready"] }
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "wanted.md"]),
      """
      ---
      title: Wanted
      status: ready
      assignee: Stevengre
      ---
      Wanted body
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "ignored.md"]),
      """
      ---
      title: Ignored
      status: ready
      assignee: someone-else
      ---
      Ignored body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
    assert issue.id == "wanted"
    assert issue.state == "status:ready"
  end

  test "local adapter returns config errors for malformed adapter filter shapes" do
    issue_root = tmp_dir!("local-filter-shape-errors")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "wanted.md"]),
      """
      ---
      title: Wanted
      status: ready
      assignee: Stevengre
      ---
      Wanted body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      adapter = "github"
      """
    )

    assert {:error, {:invalid_project_field_type, "siaan", "adapter", :map, "github"}} =
             Adapter.fetch_candidate_issues()

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"

      [projects.siaan.adapter]
      filters = "status:ready"
      """
    )

    assert {:error, {:invalid_project_field_type, "siaan", "adapter.filters", :map, "status:ready"}} =
             Adapter.fetch_candidate_issues()
  end

  test "local adapter fetches issues by state and tolerates unknown ids" do
    issue_root = tmp_dir!("local-state-fetch")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "state-fetch"
    issue_dir = Path.join([issue_root, "in-progress", slug])

    File.mkdir_p!(issue_dir)

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join(issue_dir, "issue.md"),
      """
      ---
      title: State fetch
      status: in-progress
      ---
      body
      """
    )

    File.write!(
      Path.join(issue_dir, "workpad.md"),
      """
      ---
      status: in-progress
      ---
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:ok, [issue]} = Adapter.fetch_issues_by_states(["status:in-progress"])
    assert issue.id == slug

    assert {:ok, [same_issue]} = Adapter.fetch_issue_states_by_ids([slug, "missing"])
    assert same_issue.id == slug
  end

  test "local adapter surfaces transition read errors during state refresh" do
    issue_root = tmp_dir!("local-state-refresh-errors")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "refresh-error"
    issue_dir = Path.join([issue_root, "in-progress", slug])

    File.mkdir_p!(issue_dir)

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
            when: []
      review:
        activities: []
        transitions: []
      """
    )

    File.write!(
      Path.join(issue_dir, "issue.md"),
      """
      ---
      title: Refresh error
      status: in-progress
      ---
      body
      """
    )

    File.write!(
      Path.join(issue_dir, "workpad.md"),
      """
      ---
      status: [unterminated
      ---
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:error, {:invalid_frontmatter, path, _message}} =
             Adapter.fetch_issue_states_by_ids([slug, "missing"])

    assert path == Path.join(issue_dir, "workpad.md")
  end

  test "local adapter supports orchestrator ready to in-progress transition and preserves branch metadata" do
    issue_root = tmp_dir!("local-ready-transition")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "queued-local-issue"

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
            when: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{slug}.md"]),
      """
      ---
      identifier: GH-42
      title: Queued local issue
      status: ready
      base-branch: main
      current-branch: feature/local-branch
      assignee: Stevengre
      ---
      Ready body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
    assert issue.state == "status:ready"
    assert issue.base_branch == "main"
    assert issue.current_branch == "feature/local-branch"

    assert :ok = Adapter.update_issue_state(slug, "status:in-progress")
    assert File.exists?(Path.join([issue_root, "in-progress", slug, "issue.md"]))
    assert File.exists?(Path.join([issue_root, "in-progress", slug, "workpad.md"]))

    assert {:ok, [updated_issue]} = Adapter.fetch_issue_states_by_ids([slug])
    assert updated_issue.state == "status:in-progress"
    assert updated_issue.base_branch == "main"
    assert updated_issue.current_branch == "feature/local-branch"
  end

  test "local adapter preserves YAML-significant frontmatter strings across transitions" do
    issue_root = tmp_dir!("local-frontmatter-roundtrip")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "yaml-frontmatter"

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{slug}.md"]),
      """
      ---
      identifier: GH-42
      title: "Fix #42: local-first orchestration"
      branch-note: "topic: local/first"
      status: ready
      ---
      Ready body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert :ok = Adapter.update_issue_state(slug, "status:in-progress")
    {frontmatter, _body} = LocalIssue.read_frontmatter(Path.join([issue_root, "in-progress", slug, "issue.md"]))

    assert frontmatter["identifier"] == "GH-42"
    assert frontmatter["title"] == "Fix #42: local-first orchestration"
    assert frontmatter["branch-note"] == "topic: local/first"
    assert frontmatter["status"] == "in-progress"
  end

  test "local adapter restores ready sidecars when transitioning back to in-progress" do
    issue_root = tmp_dir!("local-ready-restore")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "restored-local-issue"

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: review
            when: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{slug}.md"]),
      """
      ---
      identifier: GH-42
      title: Restored local issue
      status: ready
      ---
      Ready body
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{slug}.workpad.md"]),
      """
      ---
      status: ready
      ---

      - Prior work context.
      """
    )

    File.mkdir_p!(Path.join([issue_root, "ready", "#{slug}.artifacts"]))
    File.write!(Path.join([issue_root, "ready", "#{slug}.artifacts", "description-reviewer.md"]), "artifact")

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert :ok = Adapter.update_issue_state(slug, "status:in-progress")
    assert File.exists?(Path.join([issue_root, "in-progress", slug, "issue.md"]))
    assert File.exists?(Path.join([issue_root, "in-progress", slug, "workpad.md"]))
    assert File.read!(Path.join([issue_root, "in-progress", slug, "workpad.md"])) =~ "Prior work context."
    assert File.exists?(Path.join([issue_root, "in-progress", slug, "description-reviewer.md"]))

    {workpad_frontmatter, _body} =
      LocalIssue.read_frontmatter(Path.join([issue_root, "in-progress", slug, "workpad.md"]))

    assert workpad_frontmatter["status"] == "in-progress"
    refute File.exists?(Path.join([issue_root, "ready", "#{slug}.workpad.md"]))
    refute File.exists?(Path.join([issue_root, "ready", "#{slug}.artifacts"]))
  end

  test "local adapter returns recoverable errors for malformed issue or workpad frontmatter" do
    issue_root = tmp_dir!("local-malformed-frontmatter")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    bad_issue_slug = "bad-issue"
    bad_workpad_slug = "bad-workpad"

    File.mkdir_p!(Path.join([issue_root, "ready"]))
    File.mkdir_p!(Path.join([issue_root, "in-progress", bad_workpad_slug]))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: ready
            when: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{bad_issue_slug}.md"]),
      """
      ---
      title: [unterminated
      ---
      broken
      """
    )

    File.write!(
      Path.join([issue_root, "in-progress", bad_workpad_slug, "issue.md"]),
      """
      ---
      title: Bad workpad
      status: in-progress
      ---
      body
      """
    )

    File.write!(
      Path.join([issue_root, "in-progress", bad_workpad_slug, "workpad.md"]),
      """
      ---
      status: [unterminated
      ---
      broken
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:error, {:invalid_frontmatter, bad_issue_path, _message}} =
             Adapter.fetch_candidate_issues()

    assert String.ends_with?(bad_issue_path, "/ready/#{bad_issue_slug}.md")

    File.rm!(Path.join([issue_root, "ready", "#{bad_issue_slug}.md"]))

    assert {:error, {:invalid_frontmatter, bad_workpad_path, _message}} =
             Adapter.fetch_candidate_issues()

    assert String.ends_with?(bad_workpad_path, "/in-progress/#{bad_workpad_slug}/workpad.md")
  end

  test "local adapter returns an error when a requested transition is not declared" do
    issue_root = tmp_dir!("local-missing-transition")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "missing-transition"

    File.mkdir_p!(Path.join(issue_root, "ready"))

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      ready:
        activities:
          - skill: siaan-inprogress
        transitions: []
      """
    )

    File.write!(
      Path.join([issue_root, "ready", "#{slug}.md"]),
      """
      ---
      title: Missing transition
      status: ready
      ---
      body
      """
    )

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert {:error, {:no_declared_transition, "status:ready", "status:review"}} =
             Adapter.update_issue_state(slug, "status:review")
  end

  test "local adapter collapses an in-progress directory back to ready while preserving workpad sidecar" do
    issue_root = tmp_dir!("local-collapse-ready")
    config_path = Path.join(issue_root, "config.toml")
    workflow_path = Path.join(issue_root, "workflow.yaml")
    project_dir = Path.expand("..", File.cwd!())
    slug = "blocked-local-issue"
    issue_dir = Path.join([issue_root, "in-progress", slug])

    File.mkdir_p!(issue_dir)

    File.write!(
      config_path,
      """
      [projects.siaan]
      dir = "#{project_dir}"
      workflow = "#{workflow_path}"
      runtime = "local"
      """
    )

    File.write!(
      workflow_path,
      """
      in-progress:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: ready
            when: []
      ready:
        activities:
          - skill: siaan-inprogress
        transitions:
          - to: in-progress
      """
    )

    File.write!(
      Path.join(issue_dir, "issue.md"),
      """
      ---
      identifier: GH-42-BLOCKED
      title: Blocked local issue
      status: in-progress
      ---
      Blocked body
      """
    )

    File.write!(
      Path.join(issue_dir, "workpad.md"),
      """
      ---
      status: ready
      ---

      - Blocked on dependency.
      """
    )

    File.write!(Path.join(issue_dir, "description-reviewer.md"), "artifact")

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: config_path,
      tracker_local_project: "siaan",
      tracker_active_states: ["status:ready", "status:in-progress"],
      tracker_terminal_states: ["status:done"]
    )

    assert :ok = Adapter.update_issue_state(slug, "status:ready")
    assert File.exists?(Path.join([issue_root, "ready", "#{slug}.md"]))
    assert File.exists?(Path.join([issue_root, "ready", "#{slug}.workpad.md"]))
    assert File.exists?(Path.join([issue_root, "ready", "#{slug}.artifacts", "description-reviewer.md"]))
    refute File.exists?(issue_dir)

    assert {:ok, [issue]} = Adapter.fetch_issue_states_by_ids([slug])
    assert issue.state == "status:ready"
    assert issue.workpad_path == Path.join([issue_root, "ready", "#{slug}.workpad.md"])
  end

  test "local adapter create_comment is a no-op" do
    assert :ok = Adapter.create_comment("ignored", "ignored")
  end

  test "prompt builder renders the local skill template when a prompt template path is attached" do
    issue = %Issue{
      id: "local-1",
      identifier: "GH-42",
      title: "Orchestrator local-first",
      state: "in-progress",
      issue_path: "/tmp/issue.md",
      workpad_path: "/tmp/workpad.md",
      issue_dir: "/tmp",
      project_dir: "/repo",
      prompt_template_path: Path.expand("priv/skills/siaan-inprogress.md", File.cwd!())
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Issue path: /tmp/issue.md"
    assert prompt =~ "Workpad path: /tmp/workpad.md"
    assert prompt =~ "it is not dispatched to remote worker hosts"
    assert prompt =~ "status: review"
  end

  test "local issue uses app priv skill templates even when the tracked project is external" do
    issue_root = tmp_dir!("local-external-project-template")
    project_dir = Path.join(issue_root, "external-project")
    slug = "external-template"

    workflow = %{
      "in-progress" => %{
        activities: [%LocalWorkflow.Activity{type: :skill, name: "siaan-inprogress"}],
        transitions: []
      }
    }

    File.mkdir_p!(Path.join([issue_root, "in-progress", slug]))
    File.mkdir_p!(project_dir)

    File.write!(
      Path.join([issue_root, "in-progress", slug, "issue.md"]),
      """
      ---
      identifier: GH-42
      title: External project template
      status: in-progress
      ---
      body
      """
    )

    File.write!(
      Path.join([issue_root, "in-progress", slug, "workpad.md"]),
      """
      ---
      status: in-progress
      ---
      """
    )

    assert {:ok, issue} = LocalIssue.load_by_slug(issue_root, slug, project_dir, workflow)
    assert is_binary(issue.prompt_template_path)
    assert File.exists?(issue.prompt_template_path)
    refute String.starts_with?(issue.prompt_template_path, project_dir)

    prompt = PromptBuilder.build_prompt(issue)
    assert prompt =~ "Issue path: #{Path.join([issue_root, "in-progress", slug, "issue.md"])}"
  end

  test "prompt builder local-template path still includes allowlist context" do
    issue = %Issue{
      id: "local-allowlist",
      identifier: "GH-42",
      title: "Local allowlist",
      state: "in-progress",
      prompt_template_path: Path.expand("priv/skills/siaan-inprogress.md", File.cwd!())
    }

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      allowlist: ["Stevengre", "siaan-bot"]
    )

    prompt = PromptBuilder.build_prompt(issue)
    assert prompt =~ "Local allowlist"
  end

  test "prompt builder raises when a local template cannot be parsed" do
    bad_template = Path.join(tmp_dir!("local-bad-template"), "bad.md")
    File.write!(bad_template, "{{ issue.identifier ")

    issue = %Issue{id: "bad-template", identifier: "GH-42", prompt_template_path: bad_template}

    assert_raise RuntimeError, ~r/template_parse_error/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder local template still renders when workflow state is unavailable" do
    original_workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    SymphonyElixir.Workflow.set_workflow_file_path(Path.join(tmp_dir!("missing-workflow"), "missing.md"))

    issue = %Issue{
      id: "local-missing-workflow",
      identifier: "GH-42",
      title: "Missing workflow fallback",
      state: "in-progress",
      prompt_template_path: Path.expand("priv/skills/siaan-inprogress.md", File.cwd!())
    }

    prompt = PromptBuilder.build_prompt(issue)
    assert prompt =~ "Missing workflow fallback"
  end

  test "config validates local tracker requirements and defaults" do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_endpoint: nil,
      tracker_local_config_path: "/tmp/issues/config.toml",
      tracker_local_project: "siaan",
      tracker_active_states: nil,
      tracker_terminal_states: nil
    )

    settings = Config.settings!()
    assert settings.tracker.kind == "local"
    assert settings.tracker.endpoint == "https://api.linear.app/graphql"
    assert settings.tracker.active_states == ["status:ready", "status:in-progress"]
    assert settings.tracker.terminal_states == ["status:done"]
    assert :ok = Config.validate!()
  end

  test "config local tracker validation fails when required fields are missing" do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: nil,
      tracker_local_project: ""
    )

    assert {:error, :missing_local_project} = Config.validate!()

    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: nil,
      tracker_local_project: "siaan"
    )

    assert {:error, :missing_local_config_path} = Config.validate!()
  end

  test "tracker wrappers use local adapter fallbacks" do
    write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_local_config_path: "/tmp/issues/config.toml",
      tracker_local_project: "siaan"
    )

    assert Tracker.adapter() == Adapter
    assert :ok = Tracker.create_comment("ignored", "ignored")
    assert {:ok, false} = Tracker.has_actionable_pr_feedback?("ignored", ["Stevengre"])
    assert {:ok, false} = Tracker.has_pr_approval?("ignored")
    assert {:ok, :needs_agent, ["unsupported tracker"]} = Tracker.check_auto_merge_readiness("ignored")
    assert {:error, :unsupported_tracker} = Tracker.auto_merge_pr(123)
  end
end
