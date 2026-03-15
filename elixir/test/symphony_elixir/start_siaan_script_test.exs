defmodule SymphonyElixir.StartSiaanScriptTest do
  use SymphonyElixir.TestSupport

  test "fails fast when inline github tracker YAML is missing GITHUB_TOKEN" do
    temp_root = tmp_dir!("start-siaan-inline-tracker")
    original_script_path = Path.expand("../../../start-siaan.sh", __DIR__)
    script_path = Path.join(temp_root, "start-siaan.sh")
    elixir_symlink = Path.join(temp_root, "elixir")
    workflow_path = Path.join(temp_root, "INLINE_WORKFLOW.md")
    fake_bin = Path.join(temp_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    path_env = System.get_env("PATH")

    File.cp!(original_script_path, script_path)
    File.chmod!(script_path, 0o755)
    File.ln_s!(Path.expand("../..", __DIR__), elixir_symlink)
    File.mkdir_p!(fake_bin)
    File.write!(fake_mise, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_mise, 0o755)

    File.write!(
      workflow_path,
      "tracker: { kind: github, repo_owner: acme, repo_name: repo }\n---\nPrompt\n"
    )

    assert {output, 1} =
             System.cmd("bash", [script_path, "--workflow", workflow_path],
               env: [
                 {"PATH", "#{fake_bin}:#{path_env}"},
                 {"GITHUB_TOKEN", ""},
                 {"GH_TOKEN", ""}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "error: GITHUB_TOKEN is not set."
    assert output =~ "set it in .env, export GITHUB_TOKEN=..., or export GH_TOKEN=..."
  end
end
