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
      "state: { type: github, repo_owner: acme, repo_name: repo }\n---\nPrompt\n"
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

  test "prefers canonical state.type over legacy tracker.kind in mixed configs" do
    temp_root = tmp_dir!("start-siaan-state-precedence")
    original_script_path = Path.expand("../../../start-siaan.sh", __DIR__)
    script_path = Path.join(temp_root, "start-siaan.sh")
    elixir_symlink = Path.join(temp_root, "elixir")
    workflow_path = Path.join(temp_root, "MIXED_WORKFLOW.md")
    fake_bin = Path.join(temp_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_siaan = Path.join(temp_root, "elixir/bin/siaan")
    fake_log = Path.join(temp_root, "siaan-invocation.txt")
    path_env = System.get_env("PATH")

    File.cp!(original_script_path, script_path)
    File.chmod!(script_path, 0o755)
    File.ln_s!(Path.expand("../..", __DIR__), elixir_symlink)
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.dirname(fake_siaan))

    File.write!(
      fake_mise,
      "#!/bin/sh\nif [ \"$1\" = \"exec\" ]; then shift; fi\nif [ \"$1\" = \"--\" ]; then shift; fi\nexec \"$@\"\n"
    )

    File.chmod!(fake_mise, 0o755)
    File.write!(fake_siaan, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$SIAAN_INVOCATION_LOG\"\n")
    File.chmod!(fake_siaan, 0o755)

    File.write!(
      workflow_path,
      """
      tracker:
        kind: github
        repo_owner: acme
        repo_name: repo
      state:
        type: local
        path: ./.siaan/issues
      ---
      Prompt
      """
    )

    assert {output, 0} =
             System.cmd("bash", [script_path, "--workflow", workflow_path],
               env: [
                 {"PATH", "#{fake_bin}:#{path_env}"},
                 {"GITHUB_TOKEN", ""},
                 {"GH_TOKEN", ""},
                 {"SIAAN_INVOCATION_LOG", fake_log}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "Starting siaan with workflow: #{Path.expand(workflow_path)}"
    assert File.read!(fake_log) =~ "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
    refute output =~ "error: GITHUB_TOKEN is not set."
  end
end
