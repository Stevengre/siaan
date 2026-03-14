defmodule Mix.Tasks.SiaanInstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("siaan.install")
    :ok
  end

  test "prints help text" do
    output =
      capture_io(fn ->
        Mix.Tasks.Siaan.Install.run(["--help"])
      end)

    assert output =~ "mix siaan.install [--dry-run] [--yes]"
  end

  test "raises on invalid options" do
    assert_raise Mix.Error, ~r/Invalid options/, fn ->
      Mix.Tasks.Siaan.Install.run(["--bogus"])
    end
  end
end
