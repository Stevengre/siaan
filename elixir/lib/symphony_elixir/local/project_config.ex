defmodule SymphonyElixir.Local.ProjectConfig do
  @moduledoc """
  Loads the local issue-project configuration from `config.toml`.
  """

  defstruct [:name, :dir, :workflow, :runtime, adapter: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          workflow: String.t(),
          runtime: String.t() | nil,
          adapter: map()
        }

  @spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def load(config_path, project_name) when is_binary(config_path) and is_binary(project_name) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, document} <- parse_document(contents),
         {:ok, project} <- fetch_project(document, project_name),
         {:ok, dir} <- fetch_required_path(project, project_name, "dir"),
         {:ok, workflow} <- fetch_required_path(project, project_name, "workflow"),
         {:ok, adapter} <- validate_adapter(project, project_name) do
      resolved_dir = resolve_path(config_path, dir)

      {:ok,
       %__MODULE__{
         name: project_name,
         dir: resolved_dir,
         workflow: resolve_path(config_path, workflow, resolved_dir),
         runtime: normalize_runtime(Map.get(project, "runtime")),
         adapter: adapter
       }}
    end
  end

  defp fetch_project(%{"projects" => projects}, project_name) when is_map(projects) do
    case Map.get(projects, project_name) do
      %{} = project -> {:ok, project}
      _ -> {:error, {:missing_project, project_name}}
    end
  end

  defp fetch_project(_document, project_name), do: {:error, {:missing_project, project_name}}

  defp fetch_required_path(project, project_name, key) when is_map(project) do
    case Map.get(project, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:missing_project_field, project_name, key}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:missing_project_field, project_name, key}}
    end
  end

  defp validate_adapter(project, project_name) when is_map(project) do
    case Map.get(project, "adapter", %{}) do
      adapter when is_map(adapter) ->
        validate_adapter_filters(adapter, project_name)

      value ->
        {:error, {:invalid_project_field_type, project_name, "adapter", :map, value}}
    end
  end

  defp validate_adapter_filters(adapter, project_name) when is_map(adapter) do
    case Map.get(adapter, "filters", %{}) do
      filters when is_map(filters) ->
        {:ok, adapter}

      value ->
        {:error, {:invalid_project_field_type, project_name, "adapter.filters", :map, value}}
    end
  end

  defp parse_document(contents) when is_binary(contents) do
    lines = String.split(contents, ~r/\R/, trim: false)

    Enum.reduce_while(Enum.with_index(lines, 1), {:ok, {%{}, []}}, &reduce_document_line/2)
    |> case do
      {:ok, {document, _path}} -> {:ok, document}
      {:error, _reason} = error -> error
    end
  end

  defp reduce_document_line({raw_line, line_no}, {:ok, {acc, path}}) do
    line = raw_line |> strip_comment() |> String.trim()

    cond do
      line == "" ->
        {:cont, {:ok, {acc, path}}}

      String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
        {:cont, {:ok, {acc, parse_section(line)}}}

      true ->
        parse_assignment(line, line_no, acc, path)
    end
  end

  defp parse_section(line) do
    line
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(".", trim: true)
  end

  defp parse_assignment(line, line_no, acc, path) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        with {:ok, value} <- parse_value(String.trim(raw_value)),
             {:ok, updated_acc} <- put_in_path(acc, path ++ [key], value) do
          {:cont, {:ok, {updated_acc, path}}}
        else
          {:error, reason} ->
            {:halt, {:error, {:invalid_toml, line_no, reason}}}
        end

      _ ->
        {:halt, {:error, {:invalid_toml, line_no, :invalid_assignment}}}
    end
  end

  defp strip_comment(line) do
    {prefix, _quote?} =
      line
      |> String.to_charlist()
      |> Enum.reduce_while({[], false}, fn char, {acc, quote?} ->
        cond do
          char == ?" ->
            {:cont, {[char | acc], not quote?}}

          char == ?# and not quote? ->
            {:halt, {acc, quote?}}

          true ->
            {:cont, {[char | acc], quote?}}
        end
      end)

    prefix |> Enum.reverse() |> List.to_string()
  end

  defp parse_value(value) when value in ["true", "false"], do: {:ok, value == "true"}

  defp parse_value(value) do
    case classify_value(value) do
      :quoted -> {:ok, value |> String.trim_leading("\"") |> String.trim_trailing("\"")}
      :array -> parse_array(value)
      :inline_table -> parse_inline_table(value)
      :integer -> {:ok, String.to_integer(value)}
      :plain -> {:ok, value}
    end
  end

  defp classify_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") -> :quoted
      String.starts_with?(value, "[") and String.ends_with?(value, "]") -> :array
      String.starts_with?(value, "{") and String.ends_with?(value, "}") -> :inline_table
      Regex.match?(~r/^-?\d+$/, value) -> :integer
      true -> :plain
    end
  end

  defp parse_array(raw_value) do
    raw_items =
      raw_value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> split_top_level(",")

    values =
      raw_items
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse_value(value) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_inline_table(raw_value) do
    entries =
      raw_value
      |> String.trim_leading("{")
      |> String.trim_trailing("}")
      |> split_top_level(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(entries, {:ok, %{}}, &reduce_inline_table_entry/2)
  end

  defp reduce_inline_table_entry(entry, {:ok, acc}) do
    case String.split(entry, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        case parse_value(String.trim(raw_value)) do
          {:ok, parsed} -> {:cont, {:ok, Map.put(acc, key, parsed)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _ ->
        {:halt, {:error, :invalid_inline_table}}
    end
  end

  defp split_top_level(value, separator) do
    separator_char = String.to_charlist(separator) |> hd()

    {parts, current, _quote?, _depth} =
      value
      |> String.to_charlist()
      |> Enum.reduce({[], [], false, 0}, fn char, {parts, current, quote?, depth} ->
        cond do
          char == ?" ->
            {parts, [char | current], not quote?, depth}

          quote? ->
            {parts, [char | current], quote?, depth}

          char in [?[, ?{] ->
            {parts, [char | current], quote?, depth + 1}

          char == ?] or char == ?} ->
            {parts, [char | current], quote?, max(depth - 1, 0)}

          char == separator_char and depth == 0 ->
            {[current |> Enum.reverse() |> List.to_string() | parts], [], quote?, depth}

          true ->
            {parts, [char | current], quote?, depth}
        end
      end)

    Enum.reverse([current |> Enum.reverse() |> List.to_string() | parts])
  end

  defp put_in_path(map, [key], value) when is_map(map), do: {:ok, Map.put(map, key, value)}

  defp put_in_path(map, [key | rest], value) when is_map(map) do
    case Map.get(map, key, %{}) do
      nested when is_map(nested) ->
        case put_in_path(nested, rest, value) do
          {:ok, updated_nested} -> {:ok, Map.put(map, key, updated_nested)}
          {:error, _reason} = error -> error
        end

      nested ->
        {:error, {:invalid_section_parent, key, nested}}
    end
  end

  defp resolve_path(config_path, path), do: resolve_path(config_path, path, nil)

  defp resolve_path(config_path, path, base_dir) when is_binary(path) do
    expanded_path = expand_home(path)

    expanded_path
    |> resolve_against_base(config_path, base_dir)
    |> Path.expand()
  end

  defp resolve_against_base(expanded_path, config_path, base_dir) do
    if Path.type(expanded_path) == :absolute do
      expanded_path
    else
      Path.expand(expanded_path, candidate_root(config_path, base_dir, expanded_path))
    end
  end

  defp candidate_root(config_path, base_dir, expanded_path) do
    config_root = Path.dirname(config_path)

    if present_path?(base_dir) do
      project_root =
        base_dir
        |> expand_home()
        |> resolve_base_dir(config_root)

      candidate = Path.expand(expanded_path, project_root)
      if File.exists?(candidate), do: project_root, else: config_root
    else
      config_root
    end
  end

  defp resolve_base_dir(path, config_root) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, config_root)
  end

  defp expand_home("~/" <> tail), do: Path.join(System.user_home!(), tail)
  defp expand_home("~"), do: System.user_home!()
  defp expand_home(path), do: path

  defp normalize_runtime(value) when value in [nil, ""], do: "local"
  defp normalize_runtime(value) when is_binary(value), do: value
  defp normalize_runtime(_value), do: "local"

  defp present_path?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_path?(_value), do: false
end
