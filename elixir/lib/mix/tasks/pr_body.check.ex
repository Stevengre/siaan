defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @template_paths [
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/pull_request_template.md",
    "../.github/PULL_REQUEST_TEMPLATE.md",
    "../.github/pull_request_template.md"
  ]

  @architecture_trace_summary "<summary><b>Architecture Trace</b></summary>"
  @architecture_trace_details_regex ~r/<details>\s*#{Regex.escape(@architecture_trace_summary)}.*?<\/details>/s
  @architecture_trace_headings [
    "### Context (C4-L1)",
    "### Container (C4-L2)",
    "### Component (C4-L3)",
    "### Code Trace (C4-L4)",
    "### Decision Record"
  ]
  @decision_record_heading "### Decision Record"
  @decision_record_fields [
    "**Decision**:",
    "**Alternatives considered**:",
    "**Trade-offs**:",
    "**Why chosen**:",
    "**Implementation links**:"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        with {:ok, template_path, template} <- read_template(),
             {:ok, body} <- read_file(file_path),
             {:ok, headings} <- extract_template_headings(template, template_path),
             :ok <- lint_and_print(template_path, template, body, headings) do
          Mix.shell().info("PR body format OK")
        else
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  defp read_template do
    case Enum.find_value(@template_paths, &read_template_candidate/1) do
      {:ok, _path, _template} = result ->
        result

      nil ->
        joined_paths = Enum.join(@template_paths, ", ")
        {:error, "Unable to read PR template from any of: #{joined_paths}"}
    end
  end

  defp read_template_candidate(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, path, content}
      {:error, _reason} -> nil
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp extract_template_headings(template, template_path) do
    headings =
      Regex.scan(~r/^\#{3,6}\s+.+$/m, template)
      |> Enum.map(&hd/1)

    if headings == [] do
      {:error, "No markdown headings found in #{template_path}"}
    else
      {:ok, headings}
    end
  end

  defp lint_and_print(template_path, template, body, headings) do
    errors = lint(template, body, headings)

    if errors == [] do
      :ok
    else
      Enum.each(errors, fn err -> Mix.shell().error("ERROR: #{err}") end)

      {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
    end
  end

  defp lint(template, body, headings) do
    []
    |> check_required_headings(body, headings)
    |> check_order(body, headings)
    |> check_no_placeholders(body)
    |> check_sections_from_template(template, body, headings)
    |> check_architecture_trace_wrapper(body)
    |> check_table_section(body, headings, "### Behavior Delta")
    |> check_table_section(body, headings, "### Validation")
    |> check_numbered_section(body, headings, "### Review Focus")
    |> check_decision_record(body, headings)
  end

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> heading_position(body, heading) == :nomatch end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body, headings) do
    positions =
      headings
      |> Enum.map(&heading_position(body, &1))
      |> Enum.reject(&(&1 == :nomatch))

    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--") do
      errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."]
    else
      errors
    end
  end

  defp check_sections_from_template(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_heading_section(template, heading, headings)
      body_sections = capture_heading_sections(body, heading, headings)

      Enum.reduce(body_sections, acc, &validate_template_section(&2, heading, template_section, &1))
    end)
  end

  defp check_architecture_trace_wrapper(errors, body) do
    matches = Regex.scan(@architecture_trace_details_regex, body)

    cond do
      matches == [] and not String.contains?(body, @architecture_trace_summary) ->
        errors ++ ["Architecture Trace appendix must use the required summary heading."]

      matches == [] ->
        errors ++ ["Architecture Trace appendix must be wrapped in <details>."]

      length(matches) > 1 ->
        errors ++ ["Architecture Trace appendix must appear exactly once."]

      architecture_trace_markers_outside_appendix?(body, hd(hd(matches))) ->
        errors ++ ["Architecture Trace appendix content must appear only inside the single appendix block."]

      true ->
        errors
    end
  end

  defp check_table_section(errors, body, headings, heading) do
    body
    |> capture_heading_sections(heading, headings)
    |> Enum.reduce(errors, fn section, acc ->
      if valid_markdown_table?(section) do
        acc
      else
        acc ++ ["Section must include a markdown table with at least one data row: #{heading}"]
      end
    end)
  end

  defp check_numbered_section(errors, body, headings, heading) do
    body
    |> capture_heading_sections(heading, headings)
    |> Enum.reduce(errors, fn section, acc ->
      if valid_numbered_list?(section) do
        acc
      else
        acc ++ ["Section must include a numbered list: #{heading}"]
      end
    end)
  end

  defp check_decision_record(errors, body, headings) do
    case capture_heading_section(body, @decision_record_heading, headings) do
      nil ->
        errors

      section ->
        trimmed = normalize_decision_record_section(section)

        cond do
          trimmed == "No design decision introduced in this PR." ->
            errors

          valid_decision_record_entries?(trimmed) ->
            errors

          true ->
            errors ++
              [
                "Decision Record must either say `No design decision introduced in this PR.` or include Decision, Alternatives considered, Trade-offs, Why chosen, and Implementation links."
              ]
        end
    end
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not decision_record_without_bullets?(heading, body_section) and not Regex.match?(~r/^- /m, body_section) do
      errors ++ ["Section must include at least one bullet item: #{heading}"]
    else
      errors
    end
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section) do
      errors ++ ["Section must include at least one checkbox item: #{heading}"]
    else
      errors
    end
  end

  defp validate_template_section(errors, heading, template_section, body_section) do
    if String.trim(body_section) == "" do
      errors ++ ["Section cannot be empty: #{heading}"]
    else
      errors
      |> maybe_require_bullets(heading, template_section, body_section)
      |> maybe_require_checkboxes(heading, template_section, body_section)
    end
  end

  defp decision_record_without_bullets?(heading, body_section) do
    heading == @decision_record_heading and normalize_decision_record_section(body_section) == "No design decision introduced in this PR."
  end

  defp normalize_decision_record_section(section) do
    section
    |> String.replace(~r/\n?<\/details>\s*\z/s, "")
    |> String.trim()
  end

  defp valid_markdown_table?(section) do
    sanitized = strip_code_blocks(section)

    sanitized
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(fn chunk -> chunk == [""] end)
    |> Enum.any?(&table_block?/1)
  end

  defp table_block?([header, separator | rest]) do
    header_cell_count = cell_count(header)

    table_header_row?(header) and
      table_separator_row?(separator, header_cell_count) and
      Enum.any?(rest, &table_data_row?(&1, header_cell_count))
  end

  defp table_block?(_chunk), do: false

  defp table_header_row?(line) do
    String.starts_with?(line, "|") and String.ends_with?(line, "|") and cell_count(line) >= 2
  end

  defp table_separator_row?(line, header_cell_count) do
    String.starts_with?(line, "|") and
      String.ends_with?(line, "|") and
      cell_count(line) == header_cell_count and
      header_cell_count >= 2 and
      line
      |> parse_table_cells()
      |> Enum.all?(&Regex.match?(~r/^:?-{3,}:?$/, &1))
  end

  defp table_data_row?(line, header_cell_count) do
    valid_pipe_row = String.starts_with?(line, "|") and String.ends_with?(line, "|")
    valid_pipe_row and cell_count(line) == header_cell_count and header_cell_count >= 2
  end

  defp cell_count(line) do
    line
    |> parse_table_cells()
    |> length()
  end

  defp parse_table_cells(line) do
    line
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp valid_decision_record_entries?(section) do
    entries =
      section
      |> strip_code_blocks()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "- "))

    Enum.all?(@decision_record_fields, fn field ->
      Enum.any?(entries, &String.starts_with?(&1, "- #{field}"))
    end)
  end

  defp valid_numbered_list?(section) do
    section
    |> strip_code_blocks()
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(~r/^(?: {0,3})\d+\. /, &1))
  end

  defp strip_code_blocks(section) do
    section
    |> then(&Regex.replace(~r/```.*?```/s, &1, ""))
    |> then(&Regex.replace(~r/~~~.*?~~~/s, &1, ""))
    |> then(&Regex.replace(~r/(?:^|\n)(?: {4}|\t).*(?:\n(?: {4}|\t).*)*/m, &1, "\n"))
  end

  defp architecture_trace_markers_outside_appendix?(body, appendix_block) do
    remainder = String.replace(body, appendix_block, "", global: false)

    Enum.any?([@architecture_trace_summary | @architecture_trace_headings], &String.contains?(remainder, &1))
  end

  defp heading_position(body, heading) do
    case :binary.match(body, heading) do
      {idx, _len} -> idx
      :nomatch -> :nomatch
    end
  end

  defp capture_heading_section(doc, heading, headings) do
    doc
    |> capture_heading_sections(heading, headings)
    |> List.first()
  end

  defp capture_heading_sections(doc, heading, headings) do
    doc
    |> parse_sections(headings)
    |> Enum.filter(fn {section_heading, _content} -> section_heading == heading end)
    |> Enum.map(fn {_section_heading, content} -> content end)
  end

  defp parse_sections(doc, headings) do
    {sections, current_heading, current_content} =
      doc
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], nil, []}, &parse_section_line(&1, &2, headings))

    append_section(sections, current_heading, current_content)
  end

  defp append_section(sections, nil, _current_content), do: sections

  defp append_section(sections, current_heading, current_content) do
    sections ++ [{current_heading, current_content |> Enum.reverse() |> Enum.join("\n")}]
  end

  defp parse_section_line(line, {sections, current_heading, current_content}, headings) do
    cond do
      line in headings ->
        {append_section(sections, current_heading, current_content), line, []}

      is_nil(current_heading) ->
        {sections, current_heading, current_content}

      true ->
        {sections, current_heading, [line | current_content]}
    end
  end
end
