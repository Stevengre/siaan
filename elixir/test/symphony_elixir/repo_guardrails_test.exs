defmodule SymphonyElixir.RepoGuardrailsTest do
  use SymphonyElixir.TestSupport

  test "restrict issues policy skips enforcement outside collaborators_only" do
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
end
