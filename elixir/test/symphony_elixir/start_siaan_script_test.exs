defmodule SymphonyElixir.StartSiaanScriptTest do
  use SymphonyElixir.TestSupport

  test "fails fast when inline github tracker YAML is missing GITHUB_TOKEN" do
    script_path = Path.expand("../../../start-siaan.sh", __DIR__)
    temp_root = tmp_dir!("start-siaan-inline-tracker")
    workflow_path = Path.join(temp_root, "INLINE_WORKFLOW.md")
    fake_bin = Path.join(temp_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    path_env = System.get_env("PATH")

    File.mkdir_p!(fake_bin)
    File.write!(fake_mise, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_mise, 0o755)

    File.write!(
      workflow_path,
      "tracker: { kind: github, repo_owner: acme, repo_name: repo }\n---\nPrompt\n"
    )

    assert {output, 1} =
             System.cmd("bash", [script_path, "--workflow", workflow_path],
               env: [{"PATH", "#{fake_bin}:#{path_env}"}, {"GITHUB_TOKEN", ""}],
               stderr_to_stdout: true
             )

    assert output =~ "error: GITHUB_TOKEN is not set."
    assert output =~ "run: export GITHUB_TOKEN=..."
  end
end
