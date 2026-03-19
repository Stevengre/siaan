defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_runtime_config_path: fn _path ->
        send(parent, :runtime_config_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["runtime.yaml"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :runtime_config_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to runtime.yaml when runtime config path is missing" do
    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn path -> Path.basename(path) == "runtime.yaml" end,
      set_runtime_config_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit runtime config path override when provided" do
    parent = self()
    runtime_config_path = "tmp/custom/runtime.yaml"
    expanded_path = Path.expand(runtime_config_path)

    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn path ->
        send(parent, {:runtime_config_checked, path})
        path == expanded_path
      end,
      set_runtime_config_path: fn path ->
        send(parent, {:runtime_config_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, runtime_config_path], deps)
    assert_received {:runtime_config_checked, ^expanded_path}
    assert_received {:runtime_config_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn _path -> true end,
      set_runtime_config_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "runtime.yaml"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when runtime config file does not exist" do
    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn _path -> false end,
      set_runtime_config_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "runtime.yaml"], deps)
    assert message =~ "Runtime config file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn _path -> true end,
      set_runtime_config_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "runtime.yaml"], deps)
    assert message =~ "Failed to start Symphony with runtime config"
    assert message =~ ":boom"
  end

  test "returns ok when runtime config exists and app starts" do
    deps = %{
      default_runtime_config_path: fn -> Path.expand("runtime.yaml") end,
      file_regular?: fn _path -> true end,
      set_runtime_config_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "runtime.yaml"], deps)
  end
end
