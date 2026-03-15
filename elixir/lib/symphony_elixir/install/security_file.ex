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

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- decode(contents),
             {:ok, normalized} <- normalize(decoded) do
          {:ok, normalized}
        else
          {:error, reason} -> {:error, {:invalid_security_file, reason}}
        end

      {:error, :enoent} ->
        {:ok, @default}

      {:error, reason} ->
        {:error, {:security_file_read_failed, reason}}
    end
  end

  @spec render(t()) :: String.t()
  def render(config) do
    maintainers = Enum.map_join(config.maintainers, "\n", &"  - #{&1}")

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

  defp decode(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:yaml_decode_failed, reason}}
    end
  end

  defp normalize(%{} = decoded) do
    with {:ok, maintainers} <- normalize_maintainers(Map.get(decoded, "maintainers", [])),
         {:ok, setup} <- normalize_setup(Map.get(decoded, "setup", %{})) do
      {:ok,
       %{
         maintainers: maintainers,
         setup: setup
       }}
    end
  end

  defp normalize(other), do: {:error, {:invalid_top_level, other}}

  defp normalize_maintainers(value) do
    value
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      maintainer, {:ok, acc} when is_binary(maintainer) ->
        normalized = normalize_maintainer(maintainer)

        if normalized == "" do
          {:cont, {:ok, acc}}
        else
          {:cont, {:ok, [normalized | acc]}}
        end

      maintainer, _acc ->
        {:halt, {:error, {:invalid_maintainer, maintainer}}}
    end)
    |> case do
      {:ok, maintainers} -> {:ok, maintainers |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_maintainer(maintainer) do
    maintainer
    |> String.trim()
    |> String.replace(~r/\A@+/, "")
    |> String.downcase()
  end

  defp normalize_setup(%{} = setup) do
    with {:ok, labels} <- normalize_boolean(Map.get(setup, "labels", true), "setup.labels"),
         {:ok, issue_restriction} <-
           normalize_issue_restriction(
             Map.get(setup, "issue_restriction", "collaborators_only"),
             "setup.issue_restriction"
           ),
         {:ok, branch_protection} <-
           normalize_boolean(
             Map.get(setup, "branch_protection", true),
             "setup.branch_protection"
           ) do
      {:ok,
       %{
         labels: labels,
         issue_restriction: issue_restriction,
         branch_protection: branch_protection
       }}
    end
  end

  defp normalize_setup(other), do: {:error, {:invalid_setup, other}}

  defp normalize_boolean(value, _path) when value in [true, false], do: {:ok, value}

  defp normalize_boolean(value, path) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid_boolean, path, value}}
    end
  end

  defp normalize_boolean(value, path), do: {:error, {:invalid_boolean, path, value}}

  defp normalize_issue_restriction(value, _path) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_issue_restriction, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_issue_restriction(value, _path),
    do: {:error, {:invalid_issue_restriction, value}}

  defp bool(true), do: "true"
  defp bool(false), do: "false"
end
