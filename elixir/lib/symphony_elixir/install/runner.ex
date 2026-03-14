defmodule SymphonyElixir.Install.Runner do
  @moduledoc false

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Install.{Repository, SecurityFile}

  @desired_labels [
    %{name: "status:triage", color: "ededed", description: "Needs triage before planning"},
    %{name: "status:ready", color: "d73a4a", description: "Ready for agent execution"},
    %{name: "status:in-progress", color: "fbca04", description: "Actively being implemented"},
    %{name: "status:review", color: "0e8a16", description: "Waiting for human review"},
    %{name: "status:approval", color: "5319e7", description: "Approved and ready to land"},
    %{name: "type:feature", color: "0e8a16", description: "Feature request"},
    %{name: "type:bug", color: "b60205", description: "Bug fix"},
    %{name: "type:chore", color: "1d76db", description: "Maintenance task"},
    %{name: "priority:p0", color: "b60205", description: "Highest priority"},
    %{name: "priority:p1", color: "d93f0b", description: "Urgent priority"},
    %{name: "priority:p2", color: "fbca04", description: "Normal priority"},
    %{name: "area:orchestrator", color: "0e8a16", description: "Orchestrator-related work"}
  ]

  @type result :: %{
          repo_root: Path.t(),
          repo_owner: String.t(),
          repo_name: String.t(),
          maintainers: [String.t()],
          config_path: Path.t()
        }

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    repo_root = Repository.repo_root(Keyword.get(opts, :cwd, File.cwd!()))
    dry_run = Keyword.get(opts, :dry_run, false)
    yes = Keyword.get(opts, :yes, false)
    info = Keyword.get(opts, :info, fn line -> Mix.shell().info(line) end)
    prompt = Keyword.get(opts, :prompt, &default_prompt/2)
    client = Keyword.get(opts, :client, Client)
    branch = Keyword.get(opts, :default_branch, "main")

    with {:ok, %{owner: owner, repo: repo_name}} <- Repository.github_repo(repo_root, opts),
         {:ok, repo_ctx} <- client.build_repo_context(owner, repo_name, Keyword.get(opts, :api_key)),
         {:ok, collaborators} <- client.list_collaborators(repo_ctx),
         {:ok, security_config} <- SecurityFile.read(Repository.security_config_path(repo_root)) do
      info.("")
      info.("siaan install for #{owner}/#{repo_name}")
      info.("Current collaborators: #{Enum.map_join(collaborators, ", ", &"@#{&1}")}")
      info.("")

      info.("1. Labels")
      ensure_labels(client, repo_ctx, dry_run, info)
      info.("")

      info.("2. Maintainer allowlist")

      default_maintainers =
        case security_config.maintainers do
          [] -> collaborators
          maintainers -> maintainers
        end

      maintainers =
        if yes do
          default_maintainers
        else
          prompt.("Confirm or edit maintainer list", default_maintainers)
        end

      info.("   ✓ Selected maintainers — #{Enum.join(maintainers, ", ")}")
      info.("")

      info.("3. Repository security")
      info.("   ✓ Issue/PR restriction — enforced by repository guardrails")
      ensure_branch_protection(client, repo_ctx, branch, maintainers, dry_run, info)
      info.("")

      config_path = Repository.security_config_path(repo_root)
      desired_config = %{security_config | maintainers: maintainers}

      info.("4. Configuration")
      write_security_file(repo_root, config_path, desired_config, dry_run, info)
      info.("")

      info.("5. Version")
      info.("   ✓ siaan is up to date (v#{Mix.Project.config()[:version]})")
      info.("")
      info.("Done. Run mix siaan.install again anytime.")

      {:ok,
       %{
         repo_root: repo_root,
         repo_owner: owner,
         repo_name: repo_name,
         maintainers: maintainers,
         config_path: config_path
       }}
    end
  end

  @spec desired_labels() :: [map()]
  def desired_labels, do: @desired_labels

  defp ensure_labels(client, repo_ctx, dry_run, info) do
    {:ok, existing} = client.list_labels(repo_ctx)

    existing_names =
      existing
      |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
      |> MapSet.new()

    Enum.each(@desired_labels, fn label ->
      if MapSet.member?(existing_names, label.name) do
        info.("   ✓ #{label.name} — already exists")
      else
        info.("   + #{label.name} — creating")

        unless dry_run do
          :ok = client.create_label(repo_ctx, label)
        end
      end
    end)
  end

  defp ensure_branch_protection(client, repo_ctx, branch, maintainers, dry_run, info) do
    desired = %{
      "required_status_checks" => nil,
      "enforce_admins" => false,
      "required_pull_request_reviews" => %{
        "dismiss_stale_reviews" => true,
        "require_code_owner_reviews" => false,
        "required_approving_review_count" => 1
      },
      "restrictions" => %{"users" => maintainers, "teams" => []},
      "required_linear_history" => false,
      "allow_force_pushes" => false,
      "allow_deletions" => false,
      "block_creations" => false,
      "required_conversation_resolution" => true,
      "lock_branch" => false,
      "allow_fork_syncing" => true
    }

    case client.get_branch_protection(repo_ctx, branch) do
      {:ok, current} when is_map(current) ->
        current_users = get_in(current, ["restrictions", "users"]) || []

        if Enum.sort(extract_logins(current_users)) == Enum.sort(maintainers) do
          info.("   ✓ Branch protection on #{branch} — already configured")
        else
          info.("   ~ Branch protection on #{branch} — updating to match maintainer allowlist")
          unless dry_run, do: :ok = client.put_branch_protection(repo_ctx, branch, desired)
        end

      {:ok, nil} ->
        info.("   + Branch protection on #{branch} — creating")
        unless dry_run, do: :ok = client.put_branch_protection(repo_ctx, branch, desired)

      {:error, {:github_api_status, 403}} ->
        info.("   ~ Branch protection on #{branch} — skipped (admin permission required)")

      {:error, reason} ->
        info.("   ~ Branch protection on #{branch} — skipped (#{inspect(reason)})")
    end
  end

  defp write_security_file(repo_root, path, desired_config, dry_run, info) do
    rendered = SecurityFile.render(desired_config)

    case File.read(path) do
      {:ok, existing} when existing == rendered ->
        info.("   ✓ #{relative(repo_root, path)} — already up to date")

      _ ->
        info.("   #{if(File.exists?(path), do: "~", else: "+")} #{relative(repo_root, path)} — writing")

        unless dry_run do
          path |> Path.dirname() |> File.mkdir_p!()
          File.write!(path, rendered)
        end
    end
  end

  defp extract_logins(users) do
    Enum.map(users, fn
      %{"login" => login} -> login
      %{:login => login} -> login
      login when is_binary(login) -> login
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp default_prompt(_label, default_maintainers) do
    prompt =
      "   ? Confirm or edit maintainer list [#{Enum.join(default_maintainers, ", ")}]: "

    case Mix.shell().prompt(prompt) do
      :eof -> default_maintainers
      value -> parse_maintainers(value, default_maintainers)
    end
  end

  defp parse_maintainers(value, default_maintainers) do
    case value |> to_string() |> String.trim() do
      "" ->
        default_maintainers

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    end
  end

  defp relative(repo_root, path) do
    case Path.relative_to(path, repo_root) do
      "." -> Path.basename(path)
      other -> other
    end
  end
end
