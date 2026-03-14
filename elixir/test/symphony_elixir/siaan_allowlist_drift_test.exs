defmodule SymphonyElixir.SiaanAllowlistDriftTest do
  use SymphonyElixir.TestSupport

  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, ".github/scripts/siaan_allowlist_drift.rb")

  test "drift helper normalizes case and @ prefixes before comparing allowlists" do
    repo_root = tmp_dir!("siaan-allowlist-drift")
    security_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    workflow_path = Path.join([repo_root, "elixir", "WORKFLOW.md"])

    File.mkdir_p!(Path.dirname(security_path))
    File.mkdir_p!(Path.dirname(workflow_path))

    File.write!(
      security_path,
      """
      maintainers:
        - "@Alice"
        - BOB
      setup:
        labels: true
        issue_restriction: collaborators_only
        branch_protection: true
      """
    )

    File.write!(
      workflow_path,
      """
      ---
      security:
        dispatch_allowlist:
          - alice
          - "@bob"
      ---

      Body
      """
    )

    {output, 0} =
      System.cmd(
        "ruby",
        [@script, "--repo-root", repo_root, "--format", "json"],
        stderr_to_stdout: true
      )

    result = Jason.decode!(output)

    assert result["status"] == "ok"
    assert result["security_maintainers"] == ["alice", "bob"]
    assert result["workflow_allowlist"] == ["alice", "bob"]
  end

  test "drift helper warns instead of crashing on valid non-map security yaml" do
    repo_root = tmp_dir!("siaan-allowlist-drift-non-map")
    security_path = Path.join([repo_root, ".github", "siaan-security.yml"])
    workflow_path = Path.join([repo_root, "WORKFLOW.md"])

    File.mkdir_p!(Path.dirname(security_path))

    File.write!(
      security_path,
      """
      - alice
      - bob
      """
    )

    File.write!(
      workflow_path,
      """
      ---
      security:
        dispatch_allowlist:
          - alice
      ---
      """
    )

    {output, 0} =
      System.cmd(
        "ruby",
        [@script, "--repo-root", repo_root, "--format", "json"],
        stderr_to_stdout: true
      )

    result = Jason.decode!(output)

    assert result["status"] == "warn"
    assert result["summary"] == "Could not load .github/siaan-security.yml."
    assert Enum.any?(result["details"], &String.contains?(&1, "expected a top-level mapping"))
  end
end
