defmodule Mix.Tasks.SiaanInstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Siaan.Install
  alias SymphonyElixir.Install.Runner

  setup do
    Mix.Task.reenable("siaan.install")
    :ok
  end

  test "prints help text" do
    output =
      capture_io(fn ->
        Install.run(["--help"])
      end)

    assert output =~ "mix siaan.install [--dry-run] [--yes]"
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      Install.run(["--bogus"])
    end
  end

  test "raises when runner returns an error" do
    repo_root = Path.join(System.tmp_dir!(), "siaan-install-mix-task-error-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo_root)
    File.mkdir_p!(repo_root)

    File.cd!(repo_root, fn ->
      assert_raise Mix.Error, ~r/siaan.install failed/, fn ->
        Install.run([])
      end
    end)
  end

  test "returns ok when runner succeeds" do
    with_stubbed_runner_return("{:ok, %{}}", fn ->
      assert :ok = Install.run([])
    end)
  end

  defp with_stubbed_runner_return(return_expression, fun) do
    {Runner, beam, filename} = :code.get_object_code(Runner)
    compiler_options = Code.compiler_options()

    try do
      Code.compiler_options(ignore_module_conflict: true)
      :code.purge(Runner)
      :code.delete(Runner)

      Code.compile_string("""
      defmodule SymphonyElixir.Install.Runner do
        def run(_opts), do: #{return_expression}
      end
      """)

      fun.()
    after
      :code.purge(Runner)
      :code.delete(Runner)
      :code.load_binary(Runner, filename, beam)
      Code.compiler_options(compiler_options)
      Mix.Task.reenable("app.start")
    end
  end
end
