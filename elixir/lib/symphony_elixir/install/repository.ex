defmodule SymphonyElixir.Install.Repository do
  @moduledoc false

  @spec repo_root(Path.t()) :: Path.t()
  def repo_root(cwd \\ File.cwd!()) do
    cwd
    |> Path.expand()
    |> ascend_until_git()
  end

  @spec security_config_path(Path.t()) :: Path.t()
  def security_config_path(repo_root) do
    Path.join([repo_root, ".github", "siaan-security.yml"])
  end

  @spec workflow_paths(Path.t()) :: [Path.t()]
  def workflow_paths(repo_root) do
    [Path.join(repo_root, "WORKFLOW.md"), Path.join([repo_root, "elixir", "WORKFLOW.md"])]
  end

  @spec github_repo(Path.t(), keyword()) :: {:ok, %{owner: String.t(), repo: String.t()}} | {:error, term()}
  def github_repo(repo_root, opts \\ []) do
    with {:error, _reason} <- from_opts(opts),
         {:error, _reason} <- from_git_remote(repo_root),
         {:error, _reason} <- from_env() do
      {:error, :missing_github_repository}
    else
      {:ok, repo} -> {:ok, repo}
    end
  end

  defp ascend_until_git(path) do
    ascend_until_git(path, path)
  end

  defp ascend_until_git(path, original_path) do
    cond do
      File.exists?(Path.join(path, ".git")) -> path
      path == Path.dirname(path) -> original_path
      true -> ascend_until_git(Path.dirname(path), original_path)
    end
  end

  defp from_opts(opts) do
    owner = Keyword.get(opts, :repo_owner)
    repo = Keyword.get(opts, :repo_name)

    case normalize_pair(owner, repo) do
      {:ok, pair} -> {:ok, pair}
      :error -> {:error, :missing_repo_in_opts}
    end
  end

  defp from_env do
    case System.get_env("GITHUB_REPOSITORY") do
      nil -> {:error, :missing_github_repository_env}
      raw -> parse_repo_string(raw)
    end
  end

  defp from_git_remote(repo_root) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> parse_remote_url(String.trim(output))
      {_output, _status} -> {:error, :missing_origin_remote}
    end
  end

  defp parse_remote_url(url) when is_binary(url) do
    case parse_scp_style_remote(url) do
      {:ok, repo} ->
        parse_repo_string(repo)

      :error ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host, path: path}
          when scheme in ["http", "https", "ssh"] and is_binary(host) and is_binary(path) ->
            path
            |> String.trim_leading("/")
            |> parse_repo_string()

          _ ->
            {:error, :unsupported_remote}
        end
    end
  end

  defp parse_scp_style_remote(url) do
    case Regex.run(~r/\A[^@]+@[^:]+:(.+)\z/, url, capture: :all_but_first) do
      [repo] -> {:ok, repo}
      _ -> :error
    end
  end

  defp parse_repo_string(raw) when is_binary(raw) do
    trimmed = raw |> String.trim() |> String.trim_trailing(".git")

    case String.split(trimmed, "/", parts: 2) do
      [owner, repo] -> normalize_pair(owner, repo)
      _ -> {:error, :invalid_repo_string}
    end
  end

  defp normalize_pair(owner, repo)
       when is_binary(owner) and is_binary(repo) and owner != "" and repo != "" do
    {:ok, %{owner: owner, repo: repo}}
  end

  defp normalize_pair(_owner, _repo), do: :error
end
