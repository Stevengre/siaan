defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SSH

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    fake_ssh = install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", executable: fake_ssh, stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    fake_ssh = install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", executable: fake_ssh, stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    fake_ssh = install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", executable: fake_ssh, stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    fake_ssh = install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", executable: fake_ssh, stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 resolves executable from PATH when explicit executable is not provided" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-path-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    fake_ssh = install_fake_ssh!(test_root, trace_file)
    System.put_env("PATH", Path.dirname(fake_ssh))

    assert {:ok, {"", 0}} = SSH.run("localhost", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    fake_ssh =
      install_fake_ssh!(test_root, trace_file, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      printf 'ready\\n'
      exit 0
      """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok", executable: fake_ssh)
    assert is_port(port)
    assert_receive {^port, {:data, _data}}, 2_000
    assert_receive {^port, {:exit_status, 0}}, 2_000

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    fake_ssh =
      install_fake_ssh!(test_root, trace_file, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      printf 'ready\\n'
      exit 0
      """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", executable: fake_ssh, line: 256)
    assert is_port(port)
    assert_receive {^port, {:data, _data}}, 2_000
    assert_receive {^port, {:exit_status, 0}}, 2_000

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost bash -lc"
  end

  test "start_port/2 resolves executable from PATH with default options" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-path-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    fake_ssh =
      install_fake_ssh!(test_root, trace_file, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      printf 'ready\\n'
      exit 0
      """)

    System.put_env("PATH", Path.dirname(fake_ssh))

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    assert_receive {^port, {:data, _data}}, 2_000
    assert_receive {^port, {:exit_status, 0}}, 2_000

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    assert SSH.remote_shell_command("printf 'hello'") ==
             "bash -lc 'printf '\"'\"'hello'\"'\"''"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    fake_ssh
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
