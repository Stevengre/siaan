defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema, as: ConfigSchema
  alias SymphonyElixir.StateSync.GitHub.Adapter, as: GitHubAdapter

  defmodule StubRuntimeSource do
    @behaviour SymphonyElixir.RuntimeSource

    @impl true
    def current do
      {:ok,
       %{
         config: %{
           "state" => %{"kind" => "memory"},
           "allowlist" => ["runtime-source-user"]
         },
         prompt: "Prompt from runtime source",
         prompt_template: "Prompt from runtime source"
       }}
    end
  end

  defmodule RetryLookupGitHubClient do
    alias SymphonyElixir.StateSync.GitHub.Issue

    def fetch_candidate_issues do
      notify(:fetch_candidate_issues_called)
      {:ok, []}
    end

    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(issue_ids) do
      notify({:fetch_issue_states_by_ids_called, issue_ids})

      case Application.get_env(:symphony_elixir, :retry_lookup_issue) do
        %Issue{} = issue -> {:ok, [issue]}
        _ -> {:ok, []}
      end
    end

    def create_comment(_issue_id, _body), do: :ok
    def update_issue_state(_issue_id, _state_name), do: :ok
    def graphql(_query, _variables \\ %{}, _opts \\ []), do: {:ok, %{}}

    defp notify(message) do
      case Application.get_env(:symphony_elixir, :retry_lookup_recipient) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  test "config defaults and validation checks" do
    write_workflow_file!(RuntimeConfig.path(),
      state_api_token: nil,
      state_project_slug: nil,
      poll_interval_ms: nil,
      state_active_states: nil,
      state_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.state.active_states == ["Todo", "In Progress"]
    assert config.state.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.state.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(RuntimeConfig.path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(RuntimeConfig.path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(RuntimeConfig.path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(RuntimeConfig.path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    assert Config.execution_profile("ready_to_in_progress") == %{
             name: "ready_to_in_progress",
             session_reuse: "new_issue_session",
             codex_command: "codex app-server"
           }

    assert Config.execution_profile("review_to_in_progress") == %{
             name: "review_to_in_progress",
             session_reuse: "reuse_issue_session",
             codex_command: "codex app-server"
           }

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        " Review_To_In_Progress " => %{
          "session_reuse" => " reuse_issue_session ",
          "codex_command" => "codex --model gpt-5.3-spark app-server"
        }
      }
    )

    assert Config.execution_profile("review_to_in_progress") == %{
             name: "review_to_in_progress",
             session_reuse: "reuse_issue_session",
             codex_command: "codex --model gpt-5.3-spark app-server"
           }

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "review_to_in_progress" => %{
          "session_reuse" => "reuse_issue_session",
          "codex_command" => "   "
        }
      }
    )

    assert Config.execution_profile("review_to_in_progress") == %{
             name: "review_to_in_progress",
             session_reuse: "reuse_issue_session",
             codex_command: "codex app-server"
           }

    write_workflow_file!(RuntimeConfig.path(), execution_profiles: nil)

    assert Config.execution_profile("ready_to_in_progress") == %{
             name: "ready_to_in_progress",
             session_reuse: "new_issue_session",
             codex_command: "codex app-server"
           }

    assert {:ok, parsed_config} =
             ConfigSchema.parse(%{
               "agent" => %{"execution_profiles" => nil}
             })

    assert parsed_config.agent.execution_profiles["ready_to_in_progress"]["session_reuse"] ==
             "new_issue_session"

    assert {:ok, parsed_config} =
             ConfigSchema.parse(%{
               "agent" => %{
                 "execution_profiles" => %{
                   123 => %{"session_reuse" => "new_issue_session"}
                 }
               }
             })

    assert parsed_config.agent.execution_profiles["123"]["session_reuse"] == "new_issue_session"

    write_workflow_file!(RuntimeConfig.path(), execution_profiles: "invalid")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "ready_to_in_progress" => "invalid"
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"
    assert message =~ "profiles must be maps"

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "ready_to_in_progress" => %{"session_reuse" => "invalid"}
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"
    assert message =~ "session_reuse"

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "ready_to_in_progress" => %{
          "session_reuse" => "   ",
          "codex_command" => "codex app-server"
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"
    assert message =~ "session_reuse"

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "ready_to_in_progress" => %{
          "session_reuse" => 123,
          "codex_command" => "codex app-server"
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"
    assert message =~ "session_reuse"

    write_workflow_file!(RuntimeConfig.path(),
      execution_profiles: %{
        "ready_to_in_progress" => %{
          "session_reuse" => "new_issue_session",
          "codex_command" => 123
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution_profiles"
    assert message =~ "codex_command"

    write_workflow_file!(RuntimeConfig.path(), allowlist: ["Stevengre", "chatgpt-codex-connector[bot]"])
    assert Config.settings!().allowlist == ["Stevengre", "chatgpt-codex-connector[bot]"]

    write_workflow_file!(RuntimeConfig.path(), allowlist: [" Stevengre ", " chatgpt-codex-connector[bot] "])
    assert Config.settings!().allowlist == ["Stevengre", "chatgpt-codex-connector[bot]"]

    write_workflow_file!(RuntimeConfig.path(), allowlist: nil)
    assert Config.settings!().allowlist == []

    write_workflow_file!(RuntimeConfig.path(), allowlist: ["Stevengre", ""])
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "allowlist"

    write_workflow_file!(RuntimeConfig.path(), allowlist: "Stevengre")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "allowlist"

    write_workflow_file!(RuntimeConfig.path(), allowlist: ["Stevengre", 1])
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "allowlist"

    write_workflow_file!(RuntimeConfig.path(), state_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "state.active_states"

    write_workflow_file!(RuntimeConfig.path(),
      state_api_token: "token",
      state_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_api_token: "   ",
      state_project_slug: "project"
    )

    assert {:error, :missing_linear_api_token} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_api_token: "token",
      state_project_slug: "   "
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(RuntimeConfig.path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(RuntimeConfig.path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(RuntimeConfig.path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(RuntimeConfig.path(), state_type: "123")
    assert {:error, {:unsupported_state_type, "123"}} = Config.validate!()

    previous_github_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "fallback-github-token")

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: nil,
      state_project_slug: nil,
      state_repo_owner: nil,
      state_repo_name: nil,
      state_active_states: nil,
      state_terminal_states: nil
    )

    assert {:error, :missing_github_repo_owner} = Config.validate!()
    assert Config.settings!().state.api_key == "fallback-github-token"
    assert Config.settings!().state.endpoint == "https://api.github.com/graphql"
    assert Config.settings!().state.ready_label == "status:ready"
    assert Config.settings!().state.active_states == ["status:ready", "status:in-progress"]
    assert Config.settings!().state.terminal_states == ["closed"]

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_project_slug: "acme/repo",
      state_repo_owner: nil,
      state_repo_name: nil,
      state_active_states: nil,
      state_terminal_states: nil
    )

    assert {:error, :missing_github_repo_owner} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_repo_owner: "acme",
      state_repo_name: nil
    )

    assert {:error, :missing_github_repo_name} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_repo_owner: "acme",
      state_repo_name: "repo"
    )

    assert :ok = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "   ",
      state_repo_owner: "acme",
      state_repo_name: "repo"
    )

    assert {:error, :missing_github_api_token} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_repo_owner: "   ",
      state_repo_name: "repo"
    )

    assert {:error, :missing_github_repo_owner} = Config.validate!()

    write_workflow_file!(RuntimeConfig.path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_repo_owner: "acme",
      state_repo_name: "   "
    )

    assert {:error, :missing_github_repo_name} = Config.validate!()
  end

  test "config reads settings and prompt from the runtime source boundary" do
    Application.put_env(:symphony_elixir, :runtime_source_module, StubRuntimeSource)

    assert Config.settings!().state.type == "memory"
    assert Config.settings!().allowlist == ["runtime-source-user"]
    assert Config.workflow_prompt() == "Prompt from runtime source"
  end

  test "runtime config exposes the same path and load surface as workflow compatibility wrappers" do
    runtime_root = tmp_dir!("runtime-config-surface")
    runtime_path = Path.join(runtime_root, "runtime.yaml")
    prompt_path = Path.join(runtime_root, "prompt.md")
    original_path = SymphonyElixir.RuntimeConfig.path()

    on_exit(fn -> SymphonyElixir.RuntimeConfig.set_path(original_path) end)

    File.write!(prompt_path, "Surface prompt for {{ issue.identifier }}")

    write_runtime_config_file!(runtime_path,
      state_type: "memory",
      prompt: nil
    )

    File.write!(runtime_path, "tracker:\n  kind: memory\nprompt_template_path: prompt.md\n")

    assert :ok = SymphonyElixir.RuntimeConfig.set_path(runtime_path)
    assert SymphonyElixir.RuntimeConfig.path() == runtime_path
    assert Workflow.workflow_file_path() == runtime_path

    assert {:ok, %{config: %{"state" => %{"type" => "memory"}}, prompt: prompt}} =
             SymphonyElixir.RuntimeConfig.load()

    assert prompt == "Surface prompt for {{ issue.identifier }}"
  end

  test "yaml runtime config files are loaded through the runtime source boundary" do
    runtime_root = tmp_dir!("yaml-runtime-config")
    runtime_path = Path.join(runtime_root, "runtime.yaml")
    prompt_path = Path.join(runtime_root, "prompt.md")
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)

    write_runtime_config_file!(runtime_path,
      state_type: "memory",
      state_ready_label: "queued",
      state_active_states: ["queued", "working"],
      state_terminal_states: ["done"],
      poll_interval_ms: 15_000,
      workspace_root: Path.join(runtime_root, "workspaces"),
      max_concurrent_agents: 2,
      max_turns: 7,
      codex_command: "codex --model gpt-5.3-codex app-server",
      allowlist: ["yaml-runtime-user"],
      prompt: nil
    )

    File.write!(
      runtime_path,
      File.read!(runtime_path) <> "prompt_template_path: prompt.md\n"
    )

    File.write!(prompt_path, "YAML prompt for {{ issue.identifier }}")
    Workflow.set_workflow_file_path(runtime_path)

    issue = %Issue{
      identifier: "MT-790",
      title: "YAML runtime config",
      description: "Load prompt from yaml runtime config",
      state: "queued",
      url: "https://example.org/issues/MT-790"
    }

    assert Config.settings!().state.type == "memory"
    assert Config.settings!().state.ready_label == "queued"
    assert Config.settings!().state.active_states == ["queued", "working"]
    assert Config.settings!().allowlist == ["yaml-runtime-user"]
    assert Config.settings!().codex.command == "codex --model gpt-5.3-codex app-server"
    assert Config.workflow_prompt() == "YAML prompt for {{ issue.identifier }}"
    assert PromptBuilder.build_prompt(issue) == "YAML prompt for MT-790"
  end

  test "current GitHub workflow example is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)

    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.github.example.md", File.cwd!()))

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    state = Map.get(config, "state", %{})
    assert is_map(state)
    assert Map.get(state, "type") == "github"
    assert is_binary(Map.get(state, "repo_owner"))
    assert is_binary(Map.get(state, "repo_name"))
    assert is_list(Map.get(state, "active_states"))
    assert is_list(Map.get(state, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1"
    assert Map.get(hooks, "after_create") =~ "https://github.com/your-org-or-user/your-repo.git"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(RuntimeConfig.path(),
      state_api_token: nil,
      state_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().state.api_key == env_api_key
    assert Config.settings!().state.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(RuntimeConfig.path(),
      state_assignee: nil,
      state_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().state.assignee == env_assignee
  end

  test "runtime config path defaults to the first available runtime config candidate in the current working directory" do
    original_workflow_path = Workflow.workflow_file_path()
    runtime_yaml = Path.join(File.cwd!(), "runtime.yaml")

    on_exit(fn ->
      File.rm(runtime_yaml)
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")

    File.write!(runtime_yaml, "tracker:\n  kind: memory\n")
    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == runtime_yaml
  end

  test "runtime config path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
    assert SymphonyElixir.RuntimeConfig.path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\nstate:\n  kind: linear\n")

    assert {:ok, %{config: %{"state" => %{"type" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(RuntimeConfig.path(), state_type: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(RuntimeConfig.path(),
        workspace_root: test_root,
        state_active_states: ["Todo", "In Progress", "In Review"],
        state_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "non-active issue state tolerates a missing task supervisor when stopping a running agent" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-missing-task-supervisor-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(RuntimeConfig.path(),
        workspace_root: test_root,
        state_active_states: ["Todo", "In Progress", "In Review"],
        state_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
      assert is_pid(task_supervisor)
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)

      on_exit(fn ->
        if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)) do
          case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end
      end)

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(RuntimeConfig.path(),
        workspace_root: test_root,
        state_active_states: ["Todo", "In Progress", "In Review"],
        state_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(RuntimeConfig.path(),
        state_type: "memory",
        workspace_root: test_root,
        state_active_states: ["Todo", "In Progress", "In Review"],
        state_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    write_workflow_file!(RuntimeConfig.path(), state_type: "memory")

    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_ms = System.monotonic_time(:millisecond)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    after_ms = System.monotonic_time(:millisecond)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms, delay_type: :continuation} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_offset_between(due_at_ms, before_ms, after_ms, 1_000)
  end

  test "retry_delay_for_test keeps continuation retries on fixed delay" do
    assert Orchestrator.retry_delay_for_test(1, %{delay_type: :continuation}) == 1_000
    assert Orchestrator.retry_delay_for_test(4, %{delay_type: :continuation}) == 1_000
    assert Orchestrator.retry_delay_for_test(2, %{}) >= 20_000
  end

  test "actionable_blocker_for_test treats mergeability pending as waiting" do
    refute GitHubAdapter.actionable_blocker_for_test(["mergeability pending"])

    refute GitHubAdapter.actionable_blocker_for_test([
             "CI checks pending",
             "mergeability pending"
           ])

    assert GitHubAdapter.actionable_blocker_for_test([
             "mergeability pending",
             "unanswered PR comments"
           ])
  end

  test "abnormal worker exit increments retry attempt progressively" do
    write_workflow_file!(RuntimeConfig.path(), state_type: "memory")

    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_ms = System.monotonic_time(:millisecond)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    after_ms = System.monotonic_time(:millisecond)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_offset_between(due_at_ms, before_ms, after_ms, 40_000)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_ms = System.monotonic_time(:millisecond)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    after_ms = System.monotonic_time(:millisecond)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_offset_between(due_at_ms, before_ms, after_ms, 10_000)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "retry revalidation fetches issue by id and cleans terminal workspaces" do
    test_root = Path.join(System.tmp_dir!(), "symphony-retry-id-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "GH-42")
    File.mkdir_p!(workspace)

    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    previous_issue = Application.get_env(:symphony_elixir, :retry_lookup_issue)
    previous_recipient = Application.get_env(:symphony_elixir, :retry_lookup_recipient)

    on_exit(fn ->
      if previous_client, do: Application.put_env(:symphony_elixir, :github_client_module, previous_client)
      if is_nil(previous_client), do: Application.delete_env(:symphony_elixir, :github_client_module)

      if previous_issue do
        Application.put_env(:symphony_elixir, :retry_lookup_issue, previous_issue)
      else
        Application.delete_env(:symphony_elixir, :retry_lookup_issue)
      end

      if previous_recipient do
        Application.put_env(:symphony_elixir, :retry_lookup_recipient, previous_recipient)
      else
        Application.delete_env(:symphony_elixir, :retry_lookup_recipient)
      end

      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      state_type: "github",
      state_api_token: "gh-token",
      state_repo_owner: "acme",
      state_repo_name: "repo",
      state_terminal_states: ["closed"],
      workspace_root: workspace_root
    )

    Application.put_env(:symphony_elixir, :github_client_module, RetryLookupGitHubClient)
    Application.put_env(:symphony_elixir, :retry_lookup_recipient, self())

    Application.put_env(:symphony_elixir, :retry_lookup_issue, %SymphonyElixir.StateSync.GitHub.Issue{
      id: "42",
      number: 42,
      title: "Closed issue",
      state: "closed",
      labels: [],
      assignees: []
    })

    state = %Orchestrator.State{
      claimed: MapSet.new(["42"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      running: %{}
    }

    assert {:noreply, next_state} =
             Orchestrator.handle_retry_issue_for_test(state, "42", 1, %{identifier: "GH-42"})

    assert_receive {:fetch_issue_states_by_ids_called, ["42"]}

    refute MapSet.member?(next_state.claimed, "42")
    refute File.exists?(workspace)
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, %Issue{}, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, %Issue{}, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, %Issue{}, "worker-a") == "worker-a"
  end

  test "select_worker_host_for_test keeps local-runtime issues off ssh workers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    issue = %Issue{
      id: "issue-local-runtime",
      identifier: "GH-42",
      project_runtime: "local"
    }

    assert Orchestrator.select_worker_host_for_test(state, issue, "worker-a") == nil
  end

  test "worker_slots_available_for_test does not block local-runtime issues on full ssh hosts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    local_issue = %Issue{id: "local-issue", identifier: "GH-42", project_runtime: "local"}
    remote_issue = %Issue{id: "remote-issue", identifier: "GH-43"}

    assert Orchestrator.worker_slots_available_for_test(state, local_issue) == true
    assert Orchestrator.worker_slots_available_for_test(state, remote_issue) == false
  end

  test "worker_slots_available_for_test blocks concurrent local-runtime issues sharing a project dir" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{
          worker_host: nil,
          issue: %Issue{
            id: "issue-1",
            identifier: "GH-41",
            project_runtime: "local",
            project_dir: "/tmp/shared-project"
          }
        }
      }
    }

    conflicting_issue =
      %Issue{
        id: "issue-2",
        identifier: "GH-42",
        project_runtime: "local",
        project_dir: "/tmp/shared-project"
      }

    isolated_issue =
      %Issue{
        id: "issue-3",
        identifier: "GH-43",
        project_runtime: "local",
        project_dir: "/tmp/other-project"
      }

    assert Orchestrator.worker_slots_available_for_test(state, conflicting_issue) == false
    assert Orchestrator.worker_slots_available_for_test(state, isolated_issue) == true
  end

  test "worker_slots_available_for_test blocks reusable runners on full worker hosts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    issue = %Issue{id: "reusable-issue", identifier: "GH-44"}

    state = %Orchestrator.State{
      running: %{
        "busy-issue" => %{
          busy: true,
          worker_host: "worker-a",
          issue: %Issue{id: "busy-issue", identifier: "GH-99"}
        },
        issue.id => %{
          pid: self(),
          busy: false,
          persistent_runner: true,
          worker_host: "worker-a",
          issue: issue
        }
      }
    }

    assert Orchestrator.worker_slots_available_for_test(state, issue, "worker-a") == false
  end

  defp assert_due_offset_between(due_at_ms, earliest_ms, latest_ms, delay_ms) do
    assert due_at_ms >= earliest_ms + delay_ms
    assert due_at_ms <= latest_ms + delay_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders allowlist from workflow config" do
    workflow_prompt = "Allowlist={{ allowlist }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: workflow_prompt,
      allowlist: ["Stevengre", "chatgpt-codex-connector[bot]"]
    )

    issue = %Issue{
      identifier: "S-2",
      title: "Review automation",
      description: "Render allowlist prompt context",
      state: "Todo",
      url: "https://example.org/issues/S-2",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) ==
             "Allowlist=Stevengre, chatgpt-codex-connector[bot]"
  end

  test "prompt builder reads prompt context from the runtime source boundary" do
    Application.put_env(:symphony_elixir, :runtime_source_module, StubRuntimeSource)

    issue = %Issue{
      id: "runtime-source-prompt",
      identifier: "MT-123",
      title: "Runtime source prompt",
      description: "Body from issue"
    }

    assert PromptBuilder.build_prompt(issue) == "Prompt from runtime source"
  end

  test "prompt builder renders an empty allowlist when none is configured" do
    workflow_prompt = "Allowlist={{ allowlist }}"

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: workflow_prompt,
      allowlist: []
    )

    issue = %Issue{
      identifier: "S-3",
      title: "Review automation without reviewers",
      description: "Render empty allowlist prompt context",
      state: "Todo",
      url: "https://example.org/issues/S-3",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "Allowlist="
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a tracker issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports runtime config load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Runtime config unavailable",
      description: "Missing runtime config file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/runtime_config_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo GitHub workflow example renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.github.example.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.github.example.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a GitHub issue `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.github.example.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "Labels:"
    assert prompt =~ "templating"
    assert prompt =~ "workflow"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "Execution requirements:"
    assert prompt =~ "If the issue has `status:ready`, retarget it to `status:in-progress` before coding."
    assert prompt =~ "Open or update a PR that includes `closes #<issue-number>`."
    assert prompt =~ "Keep scope aligned to the issue body; if blocked, report blocker details in the issue."
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner sends fresh-session continuation guidance on review re-entry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-reuse"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-reuse"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-review-reuse",
             identifier: "MT-248",
             title: "Resume review re-entry",
             description: "Keep prior thread context",
             state: "Done"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-reuse",
        identifier: "MT-248",
        title: "Resume review re-entry",
        description: "Keep prior thread context",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: state_fetcher,
                 issue_turn_count: 6
               )

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert Enum.any?(lines, &String.contains?(&1, "\"method\":\"thread/start\""))

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 1
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 0) =~ "fresh physical Codex session for an existing issue session"
      assert Enum.at(turn_texts, 0) =~ "Previous issue-session turns completed: 6"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "persistent agent runner reuses the same physical Codex session across dispatches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-persistent-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-persistent"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-persistent-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-persistent-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      issue = %Issue{
        id: "issue-persistent-runner",
        identifier: "MT-248A",
        title: "Reuse persistent session",
        description: "Keep the same physical session across dispatches",
        state: "In Progress",
        url: "https://example.org/issues/MT-248A",
        labels: []
      }

      done_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert {:ok, pid} = AgentRunner.start(issue, self(), codex_command: "#{codex_binary} app-server")
      assert Process.whereis(SymphonyElixir.AgentRunnerSupervisor) |> is_pid()

      assert Enum.any?(
               DynamicSupervisor.which_children(SymphonyElixir.AgentRunnerSupervisor),
               fn {_id, child_pid, :worker, [SymphonyElixir.AgentRunner]} -> child_pid == pid end
             )

      AgentRunner.dispatch_turn(pid, issue, issue_state_fetcher: done_fetcher, max_turns: 1)

      assert_receive(
        {:codex_worker_update, "issue-persistent-runner",
         %{
           event: :session_started,
           thread_id: "thread-persistent",
           physical_session_reuse_decision: "started_new_physical_session"
         }}
      )

      assert_receive {:agent_runner_dispatch_complete, "issue-persistent-runner"}

      AgentRunner.dispatch_turn(
        pid,
        issue,
        issue_state_fetcher: done_fetcher,
        max_turns: 1,
        issue_turn_count: 1,
        reuse_physical_session: true
      )

      assert_receive(
        {:codex_worker_update, "issue-persistent-runner",
         %{
           event: :session_started,
           thread_id: "thread-persistent",
           physical_session_reuse_decision: "reused_physical_session"
         }}
      )

      assert_receive {:agent_runner_dispatch_complete, "issue-persistent-runner"}

      AgentRunner.stop(pid)
      refute Process.alive?(pid)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)
      assert Enum.count(lines, &String.contains?(&1, "\"method\":\"thread/start\"")) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 1) =~ "same physical Codex session/thread"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "persistent agent runner ignores idle app-server startup notifications" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-idle-port-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-idle-port"}}}'
            printf '%s\\n' '{"method":"thread/started","params":{"threadId":"thread-idle-port"}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-idle-port"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      issue = %Issue{
        id: "issue-idle-port",
        identifier: "MT-248A",
        title: "Ignore idle port notifications",
        description: "Late startup notifications should not leak as unexpected messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-248A",
        labels: []
      }

      done_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      log =
        capture_log(fn ->
          assert {:ok, pid} = AgentRunner.start(issue, self(), codex_command: "#{codex_binary} app-server")
          Process.sleep(150)

          AgentRunner.dispatch_turn(pid, issue, issue_state_fetcher: done_fetcher, max_turns: 1)

          assert_receive(
            {:codex_worker_update, "issue-idle-port",
             %{
               event: :session_started,
               thread_id: "thread-idle-port",
               physical_session_reuse_decision: "started_new_physical_session"
             }}
          )

          assert_receive {:agent_runner_dispatch_complete, "issue-idle-port"}

          AgentRunner.stop(pid)
          refute Process.alive?(pid)
        end)

      refute log =~ "received unexpected message in handle_info/2"
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator restart terminates lingering persistent agent runners" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-restart-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-restart"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      issue = %Issue{
        id: "issue-persistent-runner-restart",
        identifier: "MT-248B",
        title: "Restart cleanup",
        description: "Ensure persistent runners do not survive orchestrator restarts",
        state: "In Progress",
        url: "https://example.org/issues/MT-248B",
        labels: []
      }

      assert Process.whereis(SymphonyElixir.AgentRunnerSupervisor) |> is_pid()
      assert {:ok, pid} = AgentRunner.start(issue, self(), codex_command: "#{codex_binary} app-server")
      assert Process.alive?(pid)

      assert Enum.any?(
               DynamicSupervisor.which_children(SymphonyElixir.AgentRunnerSupervisor),
               fn {_id, child_pid, :worker, [SymphonyElixir.AgentRunner]} -> child_pid == pid end
             )

      orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)
      assert is_pid(orchestrator_pid)
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)

      assert {:ok, restarted_orchestrator_pid} =
               Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)

      assert is_pid(restarted_orchestrator_pid)
      assert restarted_orchestrator_pid != orchestrator_pid
      refute Process.alive?(pid)
      assert DynamicSupervisor.which_children(SymphonyElixir.AgentRunnerSupervisor) == []
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner uses the configured project directory for local runtime issues" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-local-runtime-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      project_dir = Path.join(test_root, "project")
      issue_dir = Path.join(test_root, "issues/in-progress/proof-issue")
      issue_path = Path.join(issue_dir, "issue.md")
      workpad_path = Path.join(issue_dir, "workpad.md")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(project_dir)
      File.mkdir_p!(issue_dir)

      File.write!(
        issue_path,
        """
        ---
        identifier: GH-42
        title: Orchestrator local-first
        status: in-progress
        ---
        Issue body
        """
      )

      File.write!(workpad_path, "---\nstatus: in-progress\n---\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      count=0
      printf 'CWD:%s\\n' "$PWD" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        state_type: "local",
        state_local_config_path: Path.join(test_root, "config.toml"),
        state_local_project: "siaan",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        state_active_states: ["status:in-progress"]
      )

      issue = %Issue{
        id: "proof-issue",
        identifier: "GH-42",
        title: "Orchestrator local-first",
        description: "Local runtime dispatch proof",
        state: "status:in-progress",
        issue_dir: issue_dir,
        issue_path: issue_path,
        workpad_path: workpad_path,
        project_dir: project_dir,
        project_runtime: "local",
        prompt_template_path: Path.expand("priv/skills/siaan-inprogress.md", File.cwd!()),
        base_branch: "main",
        current_branch: "gh-42-local-first-dsl"
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "status:review"}]} end
               )

      assert_receive {:worker_runtime_info, "proof-issue", %{workspace_path: runtime_path}}, 500
      assert {:ok, canonical_project_dir} = SymphonyElixir.PathSafety.canonicalize(project_dir)
      assert {:ok, canonical_issue_dir} = SymphonyElixir.PathSafety.canonicalize(issue_dir)
      assert runtime_path == canonical_project_dir

      trace_lines = File.read!(trace_file) |> String.split("\n", trim: true)
      assert Enum.member?(trace_lines, "CWD:#{canonical_project_dir}")

      turn_payload =
        trace_lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(fn payload -> payload["method"] == "turn/start" end)

      assert get_in(turn_payload, ["params", "cwd"]) == canonical_project_dir

      assert get_in(turn_payload, ["params", "sandboxPolicy"]) == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_project_dir, canonical_issue_dir],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => false,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }

      prompt_text =
        turn_payload
        |> get_in(["params", "input"])
        |> Enum.map_join("\n", &Map.get(&1, "text", ""))

      assert prompt_text =~ "Issue path: #{issue_path}"
      assert prompt_text =~ "Workpad path: #{workpad_path}"
      assert prompt_text =~ "Project directory: #{project_dir}"
      assert prompt_text =~ "Base branch: main"
      assert prompt_text =~ "Current branch: gh-42-local-first-dsl"
      assert prompt_text =~ "status: review"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps local-runtime issues off configured ssh workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-local-runtime-hosts-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      project_dir = Path.join(test_root, "project")
      issue_dir = Path.join(test_root, "issues/in-progress/proof-issue")
      issue_path = Path.join(issue_dir, "issue.md")
      workpad_path = Path.join(issue_dir, "workpad.md")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(project_dir)
      File.mkdir_p!(issue_dir)

      File.write!(
        issue_path,
        """
        ---
        identifier: GH-42
        title: Orchestrator local-first
        status: in-progress
        ---
        Issue body
        """
      )

      File.write!(workpad_path, "---\nstatus: in-progress\n---\n")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local-host"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local-host"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        state_type: "local",
        state_local_config_path: Path.join(test_root, "config.toml"),
        state_local_project: "siaan",
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-a", "worker-b"],
        codex_command: "#{codex_binary} app-server",
        state_active_states: ["status:in-progress"]
      )

      issue = %Issue{
        id: "proof-issue",
        identifier: "GH-42",
        title: "Orchestrator local-first",
        description: "Local runtime worker host proof",
        state: "status:in-progress",
        issue_dir: issue_dir,
        issue_path: issue_path,
        workpad_path: workpad_path,
        project_dir: project_dir,
        project_runtime: "local",
        prompt_template_path: Path.expand("priv/skills/siaan-inprogress.md", File.cwd!())
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "status:review"}]} end
               )

      assert_receive {:worker_runtime_info, "proof-issue", %{worker_host: worker_host, workspace_path: runtime_path}}, 500
      assert worker_host == nil
      assert {:ok, canonical_project_dir} = SymphonyElixir.PathSafety.canonicalize(project_dir)
      assert runtime_path == canonical_project_dir
    after
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
