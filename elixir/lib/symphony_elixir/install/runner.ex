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

    with {:ok, %{owner: owner, repo: repo_name}} <- Repository.github_repo(repo_root, opts),
         {:ok, repo_ctx} <- client.build_repo_context(owner, repo_name, Keyword.get(opts, :api_key)),
         {:ok, security_config} <- SecurityFile.read(Repository.security_config_path(repo_root)),
         {:ok, collaborators} <- client.list_collaborators(repo_ctx) do
      branch = resolve_default_branch(client, repo_ctx, opts)

      info.("")
      info.("siaan install for #{owner}/#{repo_name}")
      info.("Current collaborators: #{Enum.map_join(collaborators, ", ", &"@#{&1}")}")
      info.("")

      install_context = %{
        repo_root: repo_root,
        owner: owner,
        repo_name: repo_name,
        branch: branch,
        security_config: security_config,
        collaborators: collaborators,
        prompt: prompt,
        client: client,
        repo_ctx: repo_ctx,
        dry_run: dry_run,
        info: info
      }

      finish_install(install_context, yes)
    end
  end

  @spec desired_labels() :: [map()]
  def desired_labels, do: @desired_labels

  defp ensure_labels(client, repo_ctx, dry_run, info) do
    case render_label_status(client, repo_ctx, dry_run) do
      {:ok, lines} ->
        Enum.each(lines, info)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_label_status(client, repo_ctx, dry_run) do
    case client.list_labels(repo_ctx) do
      {:ok, existing} ->
        existing
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> MapSet.new()
        |> sync_missing_labels(client, repo_ctx, dry_run)

      {:error, reason} ->
        {:error, {:label_sync_failed, {:list_labels_failed, reason}}}
    end
  end

  defp sync_missing_labels(existing_names, client, repo_ctx, dry_run) do
    Enum.reduce_while(@desired_labels, {:ok, []}, fn label, {:ok, lines} ->
      sync_label_status(label, existing_names, client, repo_ctx, dry_run, lines)
    end)
  end

  defp sync_label_status(label, existing_names, client, repo_ctx, dry_run, lines) do
    if MapSet.member?(existing_names, label.name) do
      {:cont, {:ok, lines ++ ["   ✓ #{label.name} — already exists"]}}
    else
      create_missing_label_status(label, client, repo_ctx, dry_run, lines)
    end
  end

  defp ensure_branch_protection(client, repo_ctx, branch, maintainers, dry_run, info) do
    case normalize_branch_name(branch) do
      {:ok, branch_name} ->
        ensure_branch_protection_for_branch(client, repo_ctx, branch_name, maintainers, dry_run, info)

      {:error, reason} ->
        info.("   ~ Branch protection — skipped (could not determine default branch: #{inspect(reason)})")
    end
  end

  defp ensure_branch_protection_for_branch(client, repo_ctx, branch, maintainers, dry_run, info) do
    case client.get_branch_protection(repo_ctx, branch) do
      {:ok, current} when is_map(current) ->
        update_branch_protection(client, repo_ctx, branch, maintainers, current, dry_run, info)

      {:ok, nil} ->
        create_branch_protection(client, repo_ctx, branch, maintainers, dry_run, info)

      {:error, {:github_api_status, 403}} ->
        info.("   ~ Branch protection on #{branch} — skipped (admin permission required)")

      {:error, reason} ->
        info.("   ~ Branch protection on #{branch} — skipped (#{inspect(reason)})")
    end
  end

  defp finish_install(context, yes) do
    %{client: client, repo_ctx: repo_ctx, dry_run: dry_run, info: info} = context

    info.("1. Labels")

    with :ok <- ensure_labels(client, repo_ctx, dry_run, info),
         {:ok, maintainers} <- select_maintainers(context, yes) do
      info.("3. Repository security")
      info.("   ✓ Issue/PR restriction — enforced by repository guardrails")
      ensure_branch_protection(client, repo_ctx, context.branch, maintainers, dry_run, info)
      info.("")

      config_path = Repository.security_config_path(context.repo_root)
      desired_config = %{context.security_config | maintainers: maintainers}

      info.("4. Configuration")
      write_security_file(context.repo_root, config_path, desired_config, dry_run, info)
      info.("")

      info.("5. Version")
      info.("   ✓ siaan is up to date (v#{Mix.Project.config()[:version]})")
      info.("")
      info.("Done. Run mix siaan.install again anytime.")

      {:ok,
       %{
         repo_root: context.repo_root,
         repo_owner: context.owner,
         repo_name: context.repo_name,
         maintainers: maintainers,
         config_path: config_path
       }}
    end
  end

  defp select_maintainers(context, yes) do
    %{security_config: security_config, collaborators: collaborators, prompt: prompt, info: info} =
      context

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

    {:ok, maintainers}
  end

  defp create_missing_label_status(label, _client, _repo_ctx, true, lines) do
    {:cont, {:ok, lines ++ ["   + #{label.name} — creating"]}}
  end

  defp create_missing_label_status(label, client, repo_ctx, false, lines) do
    next_lines = lines ++ ["   + #{label.name} — creating"]

    case client.create_label(repo_ctx, label) do
      :ok -> {:cont, {:ok, next_lines}}
      {:error, reason} -> {:halt, {:error, {:label_sync_failed, {:create_label_failed, label.name, reason}}}}
    end
  end

  defp update_branch_protection(client, repo_ctx, branch, maintainers, current, dry_run, info) do
    desired = branch_protection_payload(maintainers, current)

    if branch_protection_matches?(current, desired) do
      info.("   ✓ Branch protection on #{branch} — already configured")
    else
      info.("   ~ Branch protection on #{branch} — updating to match install policy")
      maybe_apply_branch_protection(client, repo_ctx, branch, desired, "update", dry_run, info)
    end
  end

  defp create_branch_protection(client, repo_ctx, branch, maintainers, dry_run, info) do
    desired = branch_protection_payload(maintainers)
    info.("   + Branch protection on #{branch} — creating")
    maybe_apply_branch_protection(client, repo_ctx, branch, desired, "create", dry_run, info)
  end

  defp maybe_apply_branch_protection(_client, _repo_ctx, _branch, _desired, _action, true, _info), do: :ok

  defp maybe_apply_branch_protection(client, repo_ctx, branch, desired, action, false, info) do
    apply_branch_protection(client, repo_ctx, branch, desired, action, info)
  end

  defp branch_protection_payload(maintainers, current \\ nil) do
    normalized = normalize_branch_protection(current)
    review_defaults = normalize_pull_request_review_settings(nil)
    current_reviews = Map.get(normalized, "required_pull_request_reviews", review_defaults)

    %{
      "required_status_checks" => Map.get(normalized, "required_status_checks"),
      "enforce_admins" => false,
      "required_pull_request_reviews" =>
        %{
          "dismiss_stale_reviews" => true,
          "require_code_owner_reviews" => false,
          "required_approving_review_count" => 1,
          "require_last_push_approval" => false
        }
        |> maybe_put_optional_map("dismissal_restrictions", current_reviews["dismissal_restrictions"])
        |> maybe_put_optional_map(
          "bypass_pull_request_allowances",
          current_reviews["bypass_pull_request_allowances"]
        ),
      "restrictions" => %{
        "users" => maintainers |> Enum.sort() |> Enum.uniq(),
        "teams" => get_in(normalized, ["restrictions", "teams"]) || [],
        "apps" => get_in(normalized, ["restrictions", "apps"]) || []
      },
      "required_linear_history" => false,
      "allow_force_pushes" => false,
      "allow_deletions" => false,
      "block_creations" => false,
      "required_conversation_resolution" => true,
      "lock_branch" => false,
      "allow_fork_syncing" => true
    }
  end

  defp resolve_default_branch(client, repo_ctx, opts) do
    case Keyword.get(opts, :default_branch) do
      branch when is_binary(branch) -> branch
      _ -> client.get_default_branch(repo_ctx)
    end
  end

  defp normalize_branch_name({:ok, branch}), do: normalize_branch_name(branch)
  defp normalize_branch_name({:error, reason}), do: {:error, reason}

  defp normalize_branch_name(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> {:error, :missing_default_branch}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_branch_name(_branch), do: {:error, :missing_default_branch}

  defp apply_branch_protection(client, repo_ctx, branch, desired, action, info) do
    case client.put_branch_protection(repo_ctx, branch, desired) do
      :ok ->
        :ok

      {:error, {:github_api_status, 403}} ->
        info.("   ~ Branch protection on #{branch} — skipped (admin permission required)")

      {:error, reason} ->
        info.("   ~ Branch protection on #{branch} — #{action} skipped (#{inspect(reason)})")
    end
  end

  defp branch_protection_matches?(current, desired) do
    normalize_branch_protection(current) == normalize_branch_protection(desired)
  end

  defp normalize_branch_protection(nil) do
    %{
      "required_status_checks" => nil,
      "enforce_admins" => false,
      "required_pull_request_reviews" => normalize_pull_request_review_settings(nil),
      "restrictions" => normalize_restrictions(nil),
      "required_linear_history" => false,
      "allow_force_pushes" => false,
      "allow_deletions" => false,
      "block_creations" => false,
      "required_conversation_resolution" => true,
      "lock_branch" => false,
      "allow_fork_syncing" => true
    }
  end

  defp normalize_branch_protection(current) when is_map(current) do
    %{
      "required_status_checks" =>
        current
        |> Map.get("required_status_checks")
        |> normalize_required_status_checks(),
      "enforce_admins" => enabled_setting(Map.get(current, "enforce_admins"), false),
      "required_pull_request_reviews" =>
        current
        |> Map.get("required_pull_request_reviews")
        |> normalize_pull_request_review_settings(),
      "restrictions" =>
        current
        |> Map.get("restrictions")
        |> normalize_restrictions(),
      "required_linear_history" => enabled_setting(Map.get(current, "required_linear_history"), false),
      "allow_force_pushes" => enabled_setting(Map.get(current, "allow_force_pushes"), false),
      "allow_deletions" => enabled_setting(Map.get(current, "allow_deletions"), false),
      "block_creations" => enabled_setting(Map.get(current, "block_creations"), false),
      "required_conversation_resolution" => enabled_setting(Map.get(current, "required_conversation_resolution"), true),
      "lock_branch" => enabled_setting(Map.get(current, "lock_branch"), false),
      "allow_fork_syncing" => enabled_setting(Map.get(current, "allow_fork_syncing"), true)
    }
  end

  defp normalize_required_status_checks(nil), do: nil

  defp normalize_required_status_checks(current) when is_map(current) do
    normalized =
      %{}
      |> maybe_put("strict", Map.get(current, "strict"))
      |> maybe_put("contexts", normalize_string_list(Map.get(current, "contexts")))
      |> maybe_put("checks", normalize_status_checks(Map.get(current, "checks")))

    if map_size(normalized) == 0, do: nil, else: normalized
  end

  defp normalize_pull_request_review_settings(current) do
    base = %{
      "dismiss_stale_reviews" => boolean_setting(current, "dismiss_stale_reviews", true),
      "require_code_owner_reviews" => boolean_setting(current, "require_code_owner_reviews", false),
      "required_approving_review_count" => integer_setting(current, "required_approving_review_count", 1),
      "require_last_push_approval" => boolean_setting(current, "require_last_push_approval", false)
    }

    base
    |> maybe_put_optional_map(
      "dismissal_restrictions",
      normalize_review_actor_restrictions(current, "dismissal_restrictions")
    )
    |> maybe_put_optional_map(
      "bypass_pull_request_allowances",
      normalize_bypass_allowances(current)
    )
  end

  defp normalize_review_actor_restrictions(current, key) when is_map(current) do
    normalized = normalize_restrictions(Map.get(current, key))
    if normalized == %{"users" => [], "teams" => [], "apps" => []}, do: nil, else: Map.delete(normalized, "apps")
  end

  defp normalize_review_actor_restrictions(_current, _key), do: nil

  defp normalize_bypass_allowances(current) when is_map(current) do
    normalized = normalize_restrictions(Map.get(current, "bypass_pull_request_allowances"))
    if normalized == %{"users" => [], "teams" => [], "apps" => []}, do: nil, else: normalized
  end

  defp normalize_bypass_allowances(_current), do: nil

  defp normalize_restrictions(current) when is_map(current) do
    %{
      "users" => normalize_actor_list(Map.get(current, "users"), ["login"]),
      "teams" => normalize_actor_list(Map.get(current, "teams"), ["slug", "name"]),
      "apps" => normalize_actor_list(Map.get(current, "apps"), ["slug", "name"])
    }
  end

  defp normalize_restrictions(_current) do
    %{"users" => [], "teams" => [], "apps" => []}
  end

  defp normalize_status_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(fn
      %{} = check ->
        %{}
        |> maybe_put("context", Map.get(check, "context"))
        |> maybe_put("app_id", Map.get(check, "app_id"))

      _ ->
        %{}
    end)
    |> Enum.reject(&(map_size(&1) == 0))
    |> Enum.sort_by(&{Map.get(&1, "context"), to_string(Map.get(&1, "app_id"))})
  end

  defp normalize_status_checks(_checks), do: []

  defp normalize_actor_list(list, keys) when is_list(list) do
    list
    |> Enum.map(&normalize_actor_identifier(&1, keys))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp normalize_actor_list(_list, _keys), do: []

  defp normalize_actor_identifier(actor, _keys) when is_binary(actor) do
    actor
    |> String.trim()
    |> case do
      "" -> nil
      identifier -> identifier
    end
  end

  defp normalize_actor_identifier(actor, keys) when is_map(actor) do
    Enum.find_value(keys, fn key -> normalize_actor_identifier(Map.get(actor, key), []) end)
  end

  defp normalize_actor_identifier(_actor, _keys), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
  end

  defp normalize_string_list(_values), do: []

  defp enabled_setting(%{"enabled" => value}, default), do: enabled_setting(value, default)
  defp enabled_setting(%{enabled: value}, default), do: enabled_setting(value, default)
  defp enabled_setting(value, _default) when is_boolean(value), do: value
  defp enabled_setting(_value, default), do: default

  defp boolean_setting(current, key, default) when is_map(current) do
    case Map.get(current, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp boolean_setting(_current, _key, default), do: default

  defp integer_setting(current, key, default) when is_map(current) do
    case Map.get(current, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp integer_setting(_current, _key, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_optional_map(map, _key, nil), do: map
  defp maybe_put_optional_map(map, _key, value) when value == %{}, do: map
  defp maybe_put_optional_map(map, key, value), do: Map.put(map, key, value)

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
    Path.relative_to(path, repo_root)
  end
end
