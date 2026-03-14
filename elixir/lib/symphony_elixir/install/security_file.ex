defmodule SymphonyElixir.Install.SecurityFile do
  @moduledoc false

  @type t :: %{
          maintainers: [String.t()],
          setup: %{
            labels: boolean(),
            issue_restriction: String.t(),
            branch_protection: boolean()
          }
        }

  @default %{
    maintainers: [],
    setup: %{
      labels: true,
      issue_restriction: "collaborators_only",
      branch_protection: true
    }
  }

  @spec default() :: t()
  def default, do: @default

  @spec read(Path.t()) :: {:ok, t()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- YamlElixir.read_from_string(contents),
             normalized <- normalize(decoded) do
          {:ok, normalized}
        else
          _ -> {:ok, @default}
        end

      {:error, :enoent} ->
        {:ok, @default}

      {:error, _reason} ->
        {:ok, @default}
    end
  end

  @spec render(t()) :: String.t()
  def render(config) do
    maintainers =
      config.maintainers
      |> Enum.map(&"  - #{&1}")
      |> Enum.join("\n")

    [
      "# Maintainer usernames allowed to administer and merge changes for this repository.",
      "maintainers:",
      maintainers,
      "",
      "setup:",
      "  # Ensure the issue lifecycle label taxonomy exists and stays current.",
      "  labels: #{bool(config.setup.labels)}",
      "  # Repository issue/PR creation policy enforced by install-time guardrails.",
      "  issue_restriction: #{config.setup.issue_restriction}",
      "  # Keep default-branch protection aligned with the maintainer allowlist.",
      "  branch_protection: #{bool(config.setup.branch_protection)}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp normalize(%{} = decoded) do
    maintainers =
      decoded
      |> Map.get("maintainers", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    setup = Map.get(decoded, "setup", %{})

    %{
      maintainers: maintainers,
      setup: %{
        labels: Map.get(setup, "labels", true),
        issue_restriction: Map.get(setup, "issue_restriction", "collaborators_only"),
        branch_protection: Map.get(setup, "branch_protection", true)
      }
    }
  end

  defp bool(true), do: "true"
  defp bool(false), do: "false"
end

