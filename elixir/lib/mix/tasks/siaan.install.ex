defmodule Mix.Tasks.Siaan.Install do
  use Mix.Task

  @shortdoc "Install and maintain siaan for the current repository"

  @moduledoc """
  Install and maintain siaan for the current repository.

      mix siaan.install
      mix siaan.install --dry-run
      mix siaan.install --yes
  """

  alias SymphonyElixir.Install.Runner

  @switches [dry_run: :boolean, yes: :boolean, help: :boolean]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {[help: true], [], []} ->
        Mix.shell().info(usage())

      {opts, [], []} ->
        Mix.Task.run("app.start")

        case Runner.run(dry_run: opts[:dry_run] || false, yes: opts[:yes] || false) do
          {:ok, _result} -> :ok
          {:error, reason} -> Mix.raise("siaan.install failed: #{inspect(reason)}")
        end

      {_opts, _argv, invalid} ->
        Mix.raise("Invalid options: #{Enum.map_join(invalid, ", ", fn {key, _value} -> "--#{key}" end)}\n\n#{usage()}")
    end
  end

  defp usage do
    """
    Usage:
      mix siaan.install [--dry-run] [--yes]

    Options:
      --dry-run  Show the planned changes without applying them
      --yes      Skip interactive prompts and accept defaults
      --help     Show this help
    """
  end
end
