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

  defp make_tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
