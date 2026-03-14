defmodule SymphonyElixir.Install.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Install.{Runner, SecurityFile}

  defmodule FakeClient do
    def build_repo_context(owner, repo, token) do
      {:ok, %{repo_owner: owner, repo_name: repo, api_key: token || "token"}}
    end

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
end
