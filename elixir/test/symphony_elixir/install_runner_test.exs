defmodule SymphonyElixir.Install.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Install.{Runner, SecurityFile}

  defmodule PromptEofShell do
    @behaviour Mix.Shell

    def flush(callback \\ fn message -> message end), do: callback
    def print_app, do: :ok
    def info(_message), do: :ok
    def error(_message), do: :ok
    def prompt(_message), do: :eof
    def yes?(_message, _options \\ []), do: true
    def cmd(_command, _options \\ []), do: :ok
  end

  defmodule FakeClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice", "bob"]}
    def list_labels(_repo), do: {:ok, [%{"name" => "status:ready"}]}
    def create_label(_repo, _attrs), do: :ok
    def get_branch_protection(_repo, _branch), do: {:ok, nil}
    def put_branch_protection(_repo, _branch, _payload), do: :ok
  end

  defmodule IdempotentClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")

    def get_branch_protection(_repo, _branch) do
      {:ok, %{"restrictions" => %{"users" => [%{"login" => "alice"}]}}}
    end

    def put_branch_protection(_repo, _branch, _payload) do
      raise("branch protection should not be updated when already correct")
    end
  end

  defmodule PreserveChecksClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice", "bob"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")

    def get_branch_protection(_repo, _branch) do
      {:ok,
       %{
         "required_status_checks" => %{
           "strict" => true,
           "contexts" => ["make-all"],
           "checks" => [%{"context" => "validate-pr-description", "app_id" => 1}]
         },
         "enforce_admins" => %{"enabled" => true},
         "required_pull_request_reviews" => %{
           "dismiss_stale_reviews" => false,
           "require_code_owner_reviews" => true,
           "required_approving_review_count" => 2,
           "require_last_push_approval" => true,
           "dismissal_restrictions" => %{"users" => [%{"login" => "alice"}]},
           "bypass_pull_request_allowances" => %{
             "teams" => [%{"slug" => "release"}],
             "apps" => [%{"slug" => "deploy-bot"}]
           }
         },
         "restrictions" => %{
           "users" => [%{"login" => "alice"}],
           "teams" => [%{"slug" => "release"}],
           "apps" => [%{"slug" => "deploy-bot"}]
         },
         "required_linear_history" => %{"enabled" => true},
         "allow_force_pushes" => %{"enabled" => false},
         "allow_deletions" => %{"enabled" => false},
         "block_creations" => %{"enabled" => false},
         "required_conversation_resolution" => %{"enabled" => true},
         "lock_branch" => %{"enabled" => false},
         "allow_fork_syncing" => %{"enabled" => true}
       }}
    end

    def put_branch_protection(_repo, _branch, payload) do
      send(self(), {:branch_protection_payload, payload})
      :ok
    end
  end

  test "run/1 writes config and applies missing labels with defaults when yes is set" do
    repo_root = tmp_dir!("siaan-install")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    info = fn line -> Agent.update(messages, &[line | &1]) end

    assert {:ok, result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: FakeClient,
               info: info
             )

    assert result.maintainers == ["alice", "bob"]
    assert File.exists?(result.config_path)

    config = File.read!(result.config_path)
    assert config =~ "maintainers:"
    assert config =~ "- alice"
    assert config =~ "issue_restriction: collaborators_only"

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "status:ready — already exists"
    assert log =~ "status:review — creating"
    assert log =~ "Branch protection on main — creating"
  end

  test "run/1 respects dry-run and existing security file state" do
    repo_root = tmp_dir!("siaan-install-dry")
    config_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      SecurityFile.render(%{
        maintainers: ["alice"],
        setup: %{
          labels: true,
          issue_restriction: "collaborators_only",
          branch_protection: true
        }
      })
    )

    messages = Agent.start_link(fn -> [] end) |> elem(1)

    info = fn line -> Agent.update(messages, &[line | &1]) end

    assert {:ok, result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               dry_run: true,
               yes: true,
               client: IdempotentClient,
               info: info
             )

    assert result.maintainers == ["alice"]
    assert File.read!(config_path) =~ "- alice"

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "already exists"
    assert log =~ "Branch protection on main — already configured"
    assert log =~ ".github/siaan-security.yml — already up to date"
  end

  test "run/1 preserves existing required status checks when syncing maintainers" do
    repo_root = tmp_dir!("siaan-install-preserve-checks")

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: PreserveChecksClient,
               info: fn _line -> :ok end
             )

    assert_received {:branch_protection_payload, payload}

    assert payload["required_status_checks"] == %{
             "strict" => true,
             "contexts" => ["make-all"],
             "checks" => [%{"context" => "validate-pr-description", "app_id" => 1}]
           }

    assert payload["required_pull_request_reviews"] == %{
             "dismiss_stale_reviews" => true,
             "require_code_owner_reviews" => false,
             "required_approving_review_count" => 1,
             "require_last_push_approval" => false,
             "dismissal_restrictions" => %{"users" => ["alice"], "teams" => []},
             "bypass_pull_request_allowances" => %{
               "users" => [],
               "teams" => ["release"],
               "apps" => ["deploy-bot"]
             }
           }

    assert payload["restrictions"] == %{
             "users" => ["alice", "bob"],
             "teams" => ["release"],
             "apps" => ["deploy-bot"]
           }

    assert payload["required_linear_history"] == false
    assert payload["enforce_admins"] == true
  end

  defmodule DriftedProtectionClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")

    def get_branch_protection(_repo, _branch) do
      {:ok,
       %{
         "required_status_checks" => %{"strict" => true, "contexts" => ["make-all"]},
         "restrictions" => %{"users" => [%{"login" => "alice"}]},
         "required_conversation_resolution" => %{"enabled" => false}
       }}
    end

    def put_branch_protection(_repo, _branch, payload) do
      send(self(), {:drifted_branch_protection_payload, payload})
      :ok
    end
  end

  test "run/1 updates branch protection when managed settings drift even if maintainers already match" do
    repo_root = tmp_dir!("siaan-install-drift")

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: DriftedProtectionClient,
               info: fn _line -> :ok end
             )

    assert_received {:drifted_branch_protection_payload, payload}
    assert payload["restrictions"]["users"] == ["alice"]
    assert payload["required_conversation_resolution"] == true
  end

  defmodule DefaultBranchClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "trunk"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}

    def put_branch_protection(_repo, branch, _payload) do
      send(self(), {:default_branch_used, branch})
      :ok
    end
  end

  test "run/1 resolves branch protection against the repository default branch" do
    repo_root = tmp_dir!("siaan-install-default-branch")

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: DefaultBranchClient,
               info: fn _line -> :ok end
             )

    assert_received {:default_branch_used, "trunk"}
  end

  defmodule BranchProtectionFailureClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}
    def put_branch_protection(_repo, _branch, _payload), do: {:error, {:github_api_status, 422}}
  end

  test "run/1 fails when branch protection updates fail for non-403 responses" do
    repo_root = tmp_dir!("siaan-install-branch-protection-failure")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:error, {:github_api_status, 422}} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: BranchProtectionFailureClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    refute log =~ "Branch protection on main — create skipped ({:github_api_status, 422})"
    refute log =~ "Done. Run mix siaan.install again anytime."
  end

  test "run/0 uses the current directory when no opts are passed" do
    repo_root = tmp_dir!("siaan-install-default-run")

    File.cd!(repo_root, fn ->
      assert {:error, :missing_github_repository} = Runner.run()
    end)
  end

  defmodule LabelListFailureClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}
    def list_labels(_repo), do: {:error, {:github_api_status, 503}}
  end

  test "run/1 returns a label sync error when labels cannot be listed" do
    repo_root = tmp_dir!("siaan-install-label-list-failure")

    assert {:error, {:label_sync_failed, {:list_labels_failed, {:github_api_status, 503}}}} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: LabelListFailureClient,
               info: fn _line -> :ok end
             )
  end

  defmodule LabelCreateFailureClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}
    def list_labels(_repo), do: {:ok, [%{"name" => "status:ready"}]}
    def create_label(_repo, _attrs), do: {:error, {:github_api_status, 422}}
  end

  test "run/1 returns a label sync error when label creation fails" do
    repo_root = tmp_dir!("siaan-install-label-create-failure")

    assert {:error, {:label_sync_failed, {:create_label_failed, "status:triage", {:github_api_status, 422}}}} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: LabelCreateFailureClient,
               info: fn _line -> :ok end
             )
  end

  defmodule InvalidSecurityFileClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def list_collaborators(_repo) do
      flunk("list_collaborators should not run when the security file is invalid")
    end
  end

  test "run/1 fails before collaborator lookup when the security file is invalid" do
    repo_root = tmp_dir!("siaan-install-invalid-security-file")
    config_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "maintainers: [alice\n")

    assert {:error, {:invalid_security_file, {:yaml_decode_failed, _reason}}} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: InvalidSecurityFileClient,
               info: fn _line -> :ok end
             )
  end

  defmodule MissingDefaultBranchClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:error, :missing_default_branch}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
  end

  test "run/1 warns when the default branch lookup fails" do
    repo_root = tmp_dir!("siaan-install-missing-default-branch")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: MissingDefaultBranchClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection — skipped (could not determine default branch: :missing_default_branch)"
  end

  defmodule EmptyDefaultBranchClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "   "}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
  end

  test "run/1 warns when the default branch name is blank" do
    repo_root = tmp_dir!("siaan-install-empty-default-branch")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: EmptyDefaultBranchClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection — skipped (could not determine default branch: :missing_default_branch)"
  end

  defmodule NonBinaryDefaultBranchClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: 123
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
  end

  test "run/1 warns when the default branch name is non-binary" do
    repo_root = tmp_dir!("siaan-install-nonbinary-default-branch")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: NonBinaryDefaultBranchClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection — skipped (could not determine default branch: :missing_default_branch)"
  end

  defmodule ProtectionRead403Client do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:error, {:github_api_status, 403}}
  end

  test "run/1 warns when branch protection cannot be read without admin permission" do
    repo_root = tmp_dir!("siaan-install-protection-read-403")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: ProtectionRead403Client,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection on main — skipped (admin permission required)"
  end

  defmodule ProtectionReadFailureClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:error, :timeout}
  end

  test "run/1 warns when branch protection lookup fails generically" do
    repo_root = tmp_dir!("siaan-install-protection-read-failure")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: ProtectionReadFailureClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection on main — skipped (:timeout)"
  end

  defmodule DryRunCreationClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice", "bob"]}
    def list_labels(_repo), do: {:ok, [%{"name" => "status:ready"}]}
    def create_label(_repo, _attrs), do: raise("dry-run should not create labels")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}
    def put_branch_protection(_repo, _branch, _payload), do: raise("dry-run should not update branch protection")
  end

  test "run/1 reports planned label and branch protection changes during dry-run" do
    repo_root = tmp_dir!("siaan-install-dry-run-create")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               dry_run: true,
               yes: true,
               client: DryRunCreationClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "type:feature — creating"
    assert log =~ "Branch protection on main — creating"
  end

  defmodule ExplicitDefaultBranchClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: raise("explicit default_branch should bypass client lookup")
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}

    def put_branch_protection(_repo, branch, _payload) do
      send(self(), {:explicit_branch_used, branch})
      :ok
    end
  end

  test "run/1 honors an explicit default_branch option" do
    repo_root = tmp_dir!("siaan-install-explicit-default-branch")

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               default_branch: "release",
               yes: true,
               client: ExplicitDefaultBranchClient,
               info: fn _line -> :ok end
             )

    assert_received {:explicit_branch_used, "release"}
  end

  defmodule ProtectionWrite403Client do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}
    def put_branch_protection(_repo, _branch, _payload), do: {:error, {:github_api_status, 403}}
  end

  test "run/1 warns when branch protection writes need admin permission" do
    repo_root = tmp_dir!("siaan-install-protection-write-403")
    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: ProtectionWrite403Client,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection on main — skipped (admin permission required)"
  end

  defmodule BranchProtectionDisabledClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: raise("branch protection should be skipped when disabled")
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")
  end

  test "run/1 skips branch protection when disabled in the security file" do
    repo_root = tmp_dir!("siaan-install-branch-protection-disabled")
    config_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      SecurityFile.render(%{
        maintainers: ["alice"],
        setup: %{
          labels: true,
          issue_restriction: "collaborators_only",
          branch_protection: false
        }
      })
    )

    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: BranchProtectionDisabledClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Branch protection — disabled in .github/siaan-security.yml"
  end

  defmodule LabelsDisabledClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}
    def list_labels(_repo), do: raise("labels should be skipped when disabled")
    def create_label(_repo, _attrs), do: raise("labels should be skipped when disabled")
    def get_branch_protection(_repo, _branch), do: {:ok, nil}
    def put_branch_protection(_repo, _branch, _payload), do: :ok
  end

  test "run/1 skips label sync when disabled in the security file" do
    repo_root = tmp_dir!("siaan-install-labels-disabled")
    config_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      SecurityFile.render(%{
        maintainers: ["alice"],
        setup: %{
          labels: false,
          issue_restriction: "collaborators_only",
          branch_protection: true
        }
      })
    )

    messages = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: LabelsDisabledClient,
               info: fn line -> Agent.update(messages, &[line | &1]) end
             )

    log = Agent.get(messages, &Enum.reverse/1) |> Enum.join("\n")
    assert log =~ "Labels — disabled in .github/siaan-security.yml"
    assert log =~ "Branch protection on main — creating"
  end

  defmodule WeirdProtectionClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

    def get_default_branch(_repo), do: {:ok, "main"}
    def list_collaborators(_repo), do: {:ok, ["alice"]}

    def list_labels(_repo) do
      {:ok,
       Enum.map(Runner.desired_labels(), fn label ->
         %{"name" => label.name}
       end)}
    end

    def create_label(_repo, _attrs), do: raise("labels should not be created when already present")

    def get_branch_protection(_repo, _branch) do
      {:ok,
       %{
         "required_status_checks" => %{
           "strict" => true,
           "contexts" => "not-a-list",
           "checks" => [%{}, "oops"]
         },
         "required_pull_request_reviews" => %{
           "dismiss_stale_reviews" => "yes",
           "required_approving_review_count" => "2",
           "dismissal_restrictions" => %{"users" => [" ", 123]},
           "bypass_pull_request_allowances" => %{"users" => [" "]}
         },
         "restrictions" => %{
           "users" => [" ", 123],
           "teams" => ["core"],
           "apps" => [123]
         },
         "enforce_admins" => %{enabled: true},
         "allow_force_pushes" => %{enabled: true}
       }}
    end

    def put_branch_protection(_repo, _branch, payload) do
      send(self(), {:weird_branch_payload, payload})
      :ok
    end
  end

  test "run/1 normalizes unexpected branch protection payload shapes" do
    repo_root = tmp_dir!("siaan-install-weird-protection")

    assert {:ok, _result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: true,
               client: WeirdProtectionClient,
               info: fn _line -> :ok end
             )

    assert_received {:weird_branch_payload, payload}
    assert payload["required_status_checks"] == %{"strict" => true, "contexts" => [], "checks" => []}
    assert payload["required_pull_request_reviews"]["dismissal_restrictions"] == nil
    assert payload["required_pull_request_reviews"]["required_approving_review_count"] == 1
    assert payload["required_pull_request_reviews"]["dismiss_stale_reviews"] == true
    assert payload["restrictions"] == %{"users" => ["alice"], "teams" => ["core"], "apps" => []}
    assert payload["enforce_admins"] == true
    assert payload["allow_force_pushes"] == false
  end

  test "run/1 uses the default prompt when the shell returns eof" do
    original_shell = Mix.shell()
    Mix.shell(PromptEofShell)

    on_exit(fn -> Mix.shell(original_shell) end)

    repo_root = tmp_dir!("siaan-install-prompt-eof")

    assert {:ok, result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: false,
               client: FakeClient,
               info: fn _line -> :ok end
             )

    assert result.maintainers == ["alice", "bob"]
  end

  test "run/1 uses the default prompt and keeps defaults for blank input" do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    repo_root = tmp_dir!("siaan-install-prompt-blank")
    send(self(), {:mix_shell_input, :prompt, "   "})

    assert {:ok, result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: false,
               client: FakeClient,
               info: fn _line -> :ok end
             )

    assert result.maintainers == ["alice", "bob"]
    assert_received {:mix_shell, :prompt, [_message]}
  end

  test "run/1 uses the default prompt and parses edited maintainers" do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    repo_root = tmp_dir!("siaan-install-prompt-edited")
    send(self(), {:mix_shell_input, :prompt, "alice, bob, alice"})

    assert {:ok, result} =
             Runner.run(
               cwd: repo_root,
               repo_owner: "Stevengre",
               repo_name: "siaan",
               api_key: "token",
               yes: false,
               client: FakeClient,
               info: fn _line -> :ok end
             )

    assert result.maintainers == ["alice", "bob"]
    assert_received {:mix_shell, :prompt, [_message]}
  end
end
