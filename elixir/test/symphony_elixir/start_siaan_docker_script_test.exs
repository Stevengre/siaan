defmodule SymphonyElixir.StartSiaanDockerScriptTest do
  use SymphonyElixir.TestSupport

  test "rebases onto origin/main before starting docker compose" do
    temp_root = tmp_dir!("start-siaan-docker")
    original_script_path = Path.expand("../../../start-siaan-docker.sh", __DIR__)
    script_path = Path.join(temp_root, "start-siaan-docker.sh")
    fake_bin = Path.join(temp_root, "bin")
    fake_git = Path.join(fake_bin, "git")
    fake_docker = Path.join(fake_bin, "docker")
    git_log = Path.join(temp_root, "git.log")
    docker_log = Path.join(temp_root, "docker.log")
    path_env = System.get_env("PATH")

    File.cp!(original_script_path, script_path)
    File.chmod!(script_path, 0o755)
    File.mkdir_p!(fake_bin)
    File.write!(git_log, "")
    File.write!(docker_log, "")

    File.write!(
      fake_git,
      """
      #!/bin/sh
      printf '%s\\n' \"$*\" >> \"$GIT_LOG\"

      case \"$*\" in
        *\"status --porcelain --untracked-files=no\")
          exit 0
          ;;
        *\"symbolic-ref --quiet --short HEAD\")
          printf 'chore/proof-log-management\\n'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """
    )

    File.write!(
      fake_docker,
      """
      #!/bin/sh
      printf '%s\\n' \"$*\" >> \"$DOCKER_LOG\"
      exit 0
      """
    )

    File.chmod!(fake_git, 0o755)
    File.chmod!(fake_docker, 0o755)

    assert {output, 0} =
             System.cmd("bash", [script_path],
               cd: temp_root,
               env: [
                 {"PATH", "#{fake_bin}:#{path_env}"},
                 {"GIT_LOG", git_log},
                 {"DOCKER_LOG", docker_log}
               ],
               stderr_to_stdout: true
             )

    git_commands = File.read!(git_log)
    docker_commands = File.read!(docker_log)

    assert git_commands =~ "-C #{temp_root} status --porcelain --untracked-files=no"
    assert git_commands =~ "-C #{temp_root} symbolic-ref --quiet --short HEAD"
    assert git_commands =~ "-C #{temp_root} fetch origin main --prune"
    assert git_commands =~ "-C #{temp_root} rebase origin/main"
    assert docker_commands =~ "compose up -d --build siaan"
    assert output =~ "siaan started via docker compose"
  end

  test "follows logs when requested" do
    temp_root = tmp_dir!("start-siaan-docker-logs")
    original_script_path = Path.expand("../../../start-siaan-docker.sh", __DIR__)
    script_path = Path.join(temp_root, "start-siaan-docker.sh")
    fake_bin = Path.join(temp_root, "bin")
    fake_git = Path.join(fake_bin, "git")
    fake_docker = Path.join(fake_bin, "docker")
    docker_log = Path.join(temp_root, "docker.log")
    path_env = System.get_env("PATH")

    File.cp!(original_script_path, script_path)
    File.chmod!(script_path, 0o755)
    File.mkdir_p!(fake_bin)
    File.write!(docker_log, "")

    File.write!(
      fake_git,
      """
      #!/bin/sh
      case \"$*\" in
        *\"symbolic-ref --quiet --short HEAD\")
          printf 'chore/proof-log-management\\n'
          ;;
      esac
      exit 0
      """
    )

    File.write!(
      fake_docker,
      """
      #!/bin/sh
      printf '%s\\n' \"$*\" >> \"$DOCKER_LOG\"
      exit 0
      """
    )

    File.chmod!(fake_git, 0o755)
    File.chmod!(fake_docker, 0o755)

    assert {_output, 0} =
             System.cmd("bash", [script_path, "--follow-logs"],
               cd: temp_root,
               env: [
                 {"PATH", "#{fake_bin}:#{path_env}"},
                 {"DOCKER_LOG", docker_log}
               ],
               stderr_to_stdout: true
             )

    docker_commands = File.read!(docker_log)

    assert docker_commands =~ "compose up -d --build siaan"
    assert docker_commands =~ "compose logs -f siaan"
  end
end
