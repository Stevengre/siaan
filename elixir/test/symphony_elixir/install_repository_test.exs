defmodule SymphonyElixir.Install.RepositoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Install.Repository

  test "repo_root falls back to the provided cwd when no git root exists" do
    repo_root = make_tmp_dir!("install-repository")

    assert Repository.repo_root(repo_root) == repo_root
  end

  test "repo_root ascends to the nearest git root" do
    repo_root = make_tmp_dir!("install-repository-git")
    nested = Path.join([repo_root, "nested", "path"])

    File.mkdir_p!(nested)
    File.mkdir_p!(Path.join(repo_root, ".git"))

    assert Repository.repo_root(nested) == repo_root
  end

  test "repo_root/0 uses the current directory and workflow_paths/1 lists both workflow locations" do
    repo_root = make_tmp_dir!("install-repository-default-root")
    File.mkdir_p!(Path.join(repo_root, ".git"))

    File.cd!(repo_root, fn ->
      assert normalize_tmp_path(Repository.repo_root()) == normalize_tmp_path(repo_root)
    end)

    assert Repository.workflow_paths(repo_root) == [
             Path.join(repo_root, "WORKFLOW.md"),
             Path.join([repo_root, "elixir", "WORKFLOW.md"])
           ]
  end

  test "github_repo infers owner and repo from enterprise https remotes" do
    repo_root = git_repo_with_origin!("install-repository-enterprise-https", "https://ghe.example.com/acme/repo.git")

    assert {:ok, %{owner: "acme", repo: "repo"}} = Repository.github_repo(repo_root)
  end

  test "github_repo infers owner and repo from enterprise ssh remotes" do
    repo_root = git_repo_with_origin!("install-repository-enterprise-ssh", "git@ghe.example.com:acme/repo.git")

    assert {:ok, %{owner: "acme", repo: "repo"}} = Repository.github_repo(repo_root)
  end

  test "github_repo prefers origin remote over ambient GITHUB_REPOSITORY" do
    repo_root = git_repo_with_origin!("install-repository-prefer-origin", "https://ghe.example.com/acme/repo.git")
    System.put_env("GITHUB_REPOSITORY", "Stevengre/siaan")

    try do
      assert {:ok, %{owner: "acme", repo: "repo"}} = Repository.github_repo(repo_root)
    after
      System.delete_env("GITHUB_REPOSITORY")
    end
  end

  test "github_repo falls back through env and reports remote lookup failures" do
    repo_root = git_repo_with_origin!("install-repository-invalid-remote", "file:///tmp/not-github")

    System.put_env("GITHUB_REPOSITORY", "env-owner/env-repo")

    try do
      assert {:ok, %{owner: "env-owner", repo: "env-repo"}} = Repository.github_repo(repo_root)
    after
      System.delete_env("GITHUB_REPOSITORY")
    end

    assert {:error, :missing_github_repository} = Repository.github_repo(repo_root)

    repo_without_remote = make_tmp_dir!("install-repository-missing-origin")
    {_output, 0} = System.cmd("git", ["init"], cd: repo_without_remote, stderr_to_stdout: true)

    assert {:error, :missing_github_repository} = Repository.github_repo(repo_without_remote)
  end

  test "github_repo reports invalid repository strings from env" do
    repo_root = make_tmp_dir!("install-repository-invalid-env")
    System.put_env("GITHUB_REPOSITORY", "invalid")

    try do
      assert {:error, :missing_github_repository} = Repository.github_repo(repo_root)
    after
      System.delete_env("GITHUB_REPOSITORY")
    end
  end

  defp make_tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp git_repo_with_origin!(prefix, remote) do
    repo_root = make_tmp_dir!(prefix)

    {_output, 0} = System.cmd("git", ["init"], cd: repo_root, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: repo_root, stderr_to_stdout: true)

    repo_root
  end

  defp normalize_tmp_path(path) do
    path
    |> Path.expand()
    |> String.replace_prefix("/private/var/", "/var/")
  end
end
