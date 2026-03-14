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

  test "prints help text without running the installer when combined with other flags" do
    output =
      capture_io(fn ->
        with_stubbed_runner_return("raise(\"runner should not be called for --help\")", fn ->
          Install.run(["--help", "--yes"])
        end)
      end)

    assert output =~ "mix siaan.install [--dry-run] [--yes]"
  end

  test "prints help text when invalid options are present alongside --help" do
    output =
      capture_io(fn ->
        Install.run(["--help", "--bogus"])
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

  test "does not boot the application lifecycle before invoking the runner" do
    with_stubbed_runner_and_app_start("{:ok, %{}}", fn ->
      assert :ok = Install.run([])
      refute_received :app_start_called
    end)
  end

  test "raises when installer dependencies cannot start" do
    previous = Application.get_env(:symphony_elixir, :mix_siaan_install_dependency_starter)

    on_exit(fn ->
      restore_application_env(:symphony_elixir, :mix_siaan_install_dependency_starter, previous)
    end)

    Application.put_env(:symphony_elixir, :mix_siaan_install_dependency_starter, fn :req ->
      {:error, :req_boot_failed}
    end)

    with_stubbed_runner_return("{:ok, %{}}", fn ->
      assert_raise Mix.Error, ~r/Failed to start installer dependencies: :req_boot_failed/, fn ->
        Install.run([])
      end
    end)
  end

  defp with_stubbed_runner_return(return_expression, fun) do
    with_stubbed_modules(
      [
        {Runner,
         """
         defmodule SymphonyElixir.Install.Runner do
           def run(_opts), do: #{return_expression}
         end
         """}
      ],
      fun
    )
  end

  defp with_stubbed_runner_and_app_start(return_expression, fun) do
    with_stubbed_modules(
      [
        {Runner,
         """
         defmodule SymphonyElixir.Install.Runner do
           def run(_opts), do: #{return_expression}
         end
         """},
        {Mix.Tasks.App.Start,
         """
         defmodule Mix.Tasks.App.Start do
           use Mix.Task

           def run(_args) do
             send(self(), :app_start_called)
             :ok
           end
         end
         """}
      ],
      fun
    )
  end

  defp with_stubbed_modules(module_sources, fun) do
    originals =
      Enum.map(module_sources, fn {module, _source} ->
        {module, beam, filename} = :code.get_object_code(module)
        %{module: module, beam: beam, filename: filename}
      end)

    compiler_options = Code.compiler_options()

    try do
      Code.compiler_options(ignore_module_conflict: true)

      Enum.each(module_sources, fn {module, _source} ->
        :code.purge(module)
        :code.delete(module)
      end)

      Enum.each(module_sources, fn {_module, source} ->
        Code.compile_string(source)
      end)

      fun.()
    after
      Enum.reverse(originals)
      |> Enum.each(fn %{module: module, beam: original_beam, filename: original_filename} ->
        :code.purge(module)
        :code.delete(module)
        :code.load_binary(module, original_filename, original_beam)
      end)

      Code.compiler_options(compiler_options)
      Mix.Task.reenable("app.start")
    end
  end

  defp restore_application_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_application_env(app, key, value), do: Application.put_env(app, key, value)
end
