defmodule SymphonyElixir.RepoGuardrailsTest do
  use SymphonyElixir.TestSupport

  test "restrict issues policy skips enforcement only when restriction is disabled" do
    repo_root = Path.expand("../../..", __DIR__)
    script = Path.join(repo_root, ".github/scripts/restrict_issues_prs_policy.js")

    {output, 0} =
      System.cmd("node", [script, "disabled", "OutsideUser", "@Alice, Bob"], stderr_to_stdout: true)

    result = Jason.decode!(output)

    assert result == %{
             "allowlist" => ["alice", "bob"],
             "author" => "outsideuser",
             "authorAllowed" => false,
             "issueRestriction" => "disabled",
             "shouldEnforceRestriction" => false
           }
  end

  test "restrict issues policy enforces on unknown issue restriction values" do
    repo_root = Path.expand("../../..", __DIR__)
    script = Path.join(repo_root, ".github/scripts/restrict_issues_prs_policy.js")

    {output, 0} =
      System.cmd("node", [script, "collaborator_only", "OutsideUser", "@Alice, Bob"], stderr_to_stdout: true)

    result = Jason.decode!(output)

    assert result == %{
             "allowlist" => ["alice", "bob"],
             "author" => "outsideuser",
             "authorAllowed" => false,
             "issueRestriction" => "collaborator_only",
             "shouldEnforceRestriction" => true
           }
  end

  test "restrict issues policy normalizes allowlist entries during enforcement" do
    repo_root = Path.expand("../../..", __DIR__)
    script = Path.join(repo_root, ".github/scripts/restrict_issues_prs_policy.js")

    {output, 0} =
      System.cmd(
        "node",
        [script, "collaborators_only", "@Alice", "@alice, Bob, @ALICE"],
        stderr_to_stdout: true
      )

    result = Jason.decode!(output)

    assert result["allowlist"] == ["alice", "bob"]
    assert result["author"] == "alice"
    assert result["authorAllowed"] == true
    assert result["shouldEnforceRestriction"] == true
  end

  test "restrict issues policy skips enforcement when the allowlist only contains the repo-owner fallback" do
    repo_root = Path.expand("../../..", __DIR__)
    script = Path.join(repo_root, ".github/scripts/restrict_issues_prs_policy.js")

    js = """
    const policy = require(process.argv[1]);
    process.stdout.write(JSON.stringify({
      skipWithFallbackOnly: policy.shouldSkipFallbackOnlyEnforcement(['stevengre'], 'true'),
      enforceWithConfiguredMaintainers: policy.shouldSkipFallbackOnlyEnforcement(['stevengre', 'alice'], 'true'),
      enforceWhenFallbackFlagIsFalse: policy.shouldSkipFallbackOnlyEnforcement(['stevengre'], 'false')
    }));
    """

    {output, 0} = System.cmd("node", ["-e", js, script], stderr_to_stdout: true)

    assert Jason.decode!(output) == %{
             "skipWithFallbackOnly" => true,
             "enforceWithConfiguredMaintainers" => false,
             "enforceWhenFallbackFlagIsFalse" => false
           }
  end

  test "siaan_allowlist_drift.rb treats case-only and @-prefixed login differences as equal" do
    repo_root = Path.expand("../../..", __DIR__)
    script = Path.join(repo_root, ".github/scripts/siaan_allowlist_drift.rb")
    temp_repo = tmp_dir!("siaan-allowlist-drift-normalization")
    security_dir = Path.join(temp_repo, ".github")

    File.mkdir_p!(security_dir)

    File.write!(
      Path.join(security_dir, "siaan-security.yml"),
      """
      maintainers:
        - \"@Stevengre\"
      setup:
        labels: true
        issue_restriction: collaborators_only
        branch_protection: true
      """
    )

    File.write!(
      Path.join(temp_repo, "WORKFLOW.md"),
      """
      ---
      security:
        dispatch_allowlist:
          - stevengre
      ---
      """
    )

    {output, 0} =
      System.cmd("ruby", [script, "--repo-root", temp_repo, "--format", "json"], stderr_to_stdout: true)

    result = Jason.decode!(output)

    assert result["status"] == "ok"
    assert result["security_maintainers"] == ["stevengre"]
    assert result["workflow_allowlist"] == ["stevengre"]
  end

  test "restrict issues workflow falls back to the repo owner allowlist when security yaml is invalid" do
    repo_root = Path.expand("../../..", __DIR__)
    workflow = File.read!(Path.join(repo_root, ".github/workflows/restrict-issues-prs.yml"))

    [_, ruby_block] = String.split(workflow, "ruby <<'RUBY'\n", parts: 2)
    [run_block | _] = String.split(ruby_block, "\n          RUBY", parts: 2)

    temp_repo = tmp_dir!("restrict-issues-parse-fallback")
    output_path = Path.join(temp_repo, "github-output.txt")
    File.mkdir_p!(Path.join(temp_repo, ".github"))
    File.write!(Path.join([temp_repo, ".github", "siaan-security.yml"]), "maintainers: [alice\n")

    {output, 0} =
      System.cmd(
        "bash",
        ["-lc", "ruby <<'RUBY'\n#{run_block}\nRUBY"],
        cd: temp_repo,
        env: [{"REPO_OWNER", "Stevengre"}, {"GITHUB_OUTPUT", output_path}],
        stderr_to_stdout: true
      )

    assert output == ""

    outputs =
      output_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Map.new(fn [key, value] -> {key, value} end)

    assert outputs["maintainers"] == "stevengre"
    assert outputs["issue_restriction"] == "collaborators_only"
    assert outputs["config_parse_error"] == "true"
    assert outputs["fallback_only"] == "true"
  end

  test "restrict issues workflow falls back to the repo owner allowlist when security yaml uses aliases" do
    repo_root = Path.expand("../../..", __DIR__)
    workflow = File.read!(Path.join(repo_root, ".github/workflows/restrict-issues-prs.yml"))

    [_, ruby_block] = String.split(workflow, "ruby <<'RUBY'\n", parts: 2)
    [run_block | _] = String.split(ruby_block, "\n          RUBY", parts: 2)

    temp_repo = tmp_dir!("restrict-issues-alias-fallback")
    output_path = Path.join(temp_repo, "github-output.txt")
    File.mkdir_p!(Path.join(temp_repo, ".github"))

    File.write!(
      Path.join([temp_repo, ".github", "siaan-security.yml"]),
      """
      maintainers: &owners
        - alice
      setup:
        labels: true
      copy: *owners
      """
    )

    {output, 0} =
      System.cmd(
        "bash",
        ["-lc", "ruby <<'RUBY'\n#{run_block}\nRUBY"],
        cd: temp_repo,
        env: [{"REPO_OWNER", "Stevengre"}, {"GITHUB_OUTPUT", output_path}],
        stderr_to_stdout: true
      )

    assert output == ""

    outputs =
      output_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Map.new(fn [key, value] -> {key, value} end)

    assert outputs["maintainers"] == "stevengre"
    assert outputs["issue_restriction"] == "collaborators_only"
    assert outputs["config_parse_error"] == "true"
    assert outputs["fallback_only"] == "true"
  end
end
