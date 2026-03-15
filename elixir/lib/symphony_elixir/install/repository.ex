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
    [
      Path.join(repo_root, "WORKFLOW.md"),
      Path.join([repo_root, "elixir", "WORKFLOW.md"]),
      Path.join([repo_root, "elixir", "WORKFLOW.github.example.md"])
    ]
  end

  @spec github_rest_endpoint(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def github_rest_endpoint(repo_root) do
    with {:ok, remote_url} <- origin_remote_url(repo_root),
         {:ok, remote_target} <- parse_remote_target(remote_url) do
      {:ok, rest_endpoint_for_target(remote_target)}
    end
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
    with {:ok, remote_url} <- origin_remote_url(repo_root),
         {:ok, %{owner: owner, repo: repo}} <- parse_remote_target(remote_url) do
      {:ok, %{owner: owner, repo: repo}}
    end
  end

  defp origin_remote_url(repo_root) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :missing_origin_remote}
    end
  end

  defp parse_remote_target(url) when is_binary(url) do
    case parse_scp_style_remote(url) do
      {:ok, %{host: host, repo: repo}} ->
        with {:ok, %{owner: owner, repo: repo_name}} <- parse_repo_string(repo) do
          {:ok,
           %{
             owner: owner,
             repo: repo_name,
             host: host,
             endpoint_scheme: "https",
             endpoint_port: nil
           }}
        end

      :error ->
        parse_uri_remote_target(URI.parse(url))
    end
  end

  defp parse_uri_remote_target(%URI{scheme: scheme, host: host, path: path, port: port})
       when scheme in ["http", "https", "ssh"] and is_binary(host) and is_binary(path) do
    with {:ok, %{owner: owner, repo: repo}} <-
           path
           |> String.trim_leading("/")
           |> parse_repo_string() do
      {endpoint_scheme, endpoint_port} =
        case scheme do
          "ssh" -> {"https", nil}
          other -> {other, port}
        end

      {:ok,
       %{
         owner: owner,
         repo: repo,
         host: host,
         endpoint_scheme: endpoint_scheme,
         endpoint_port: endpoint_port
       }}
    end
  end

  defp parse_uri_remote_target(_uri), do: {:error, :unsupported_remote}

  defp parse_scp_style_remote(url) do
    if String.contains?(url, "://") do
      :error
    else
      case Regex.run(~r/\A[^@]+@([^:]+):(.+)\z/, url, capture: :all_but_first) do
        [host, repo] -> {:ok, %{host: host, repo: repo}}
        _ -> :error
      end
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

  defp rest_endpoint_for_target(%{
         host: host,
         endpoint_scheme: endpoint_scheme,
         endpoint_port: endpoint_port
       })
       when is_binary(host) and is_binary(endpoint_scheme) do
    if String.downcase(host) == "github.com" do
      "https://api.github.com"
    else
      port_segment =
        case endpoint_port do
          port when is_integer(port) and port not in [80, 443] -> ":#{port}"
          _ -> ""
        end

      "#{endpoint_scheme}://#{host}#{port_segment}/api/v3"
    end
  end
end
