defmodule SymphonyElixir.WorkflowEngine.MermaidParser do
  @moduledoc """
  Parses a constrained Mermaid `stateDiagram` into a workflow state machine.
  """

  alias SymphonyElixir.WorkflowEngine.StateMachine
  alias SymphonyElixir.WorkflowEngine.StateMachine.{State, Transition}
  @end_state_id StateMachine.end_state_id()

  @state_declaration ~r/^state\s+"(?<label>[^"]+)"\s+as\s+(?<id>[A-Za-z0-9:_-]+)$|^state\s+(?<simple_id>[A-Za-z0-9:_-]+)$/
  @transition_declaration ~r/^(?<source>\[\*\]|[A-Za-z0-9:_-]+)\s+-->\s+(?<target>\[\*\]|[A-Za-z0-9:_-]+)(?:\s*:\s*(?<label>.+))?$/
  @note_start ~r/^note\s+(?:left|right|top|bottom)\s+of\s+(?<id>[A-Za-z0-9:_-]+)$/
  @annotation ~r/\[(?<key>[a-z_]+)\s*:\s*(?<value>[^\]]+)\]/

  @spec parse(String.t(), keyword()) :: {:ok, StateMachine.t()} | {:error, term()}
  def parse(diagram, opts \\ []) when is_binary(diagram) and is_list(opts) do
    with {:ok, lines} <- normalize_lines(diagram),
         {:ok, machine} <- parse_lines(lines, %StateMachine{id: Keyword.get(opts, :id, "workflow")}) do
      {:ok, machine}
    end
  end

  defp normalize_lines(diagram) do
    lines =
      diagram
      |> String.split(~r/\R/, trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "%%")))

    case lines do
      [header | rest] when header in ["stateDiagram", "stateDiagram-v2"] -> {:ok, rest}
      _ -> {:error, :invalid_mermaid_state_diagram}
    end
  end

  defp parse_lines([], machine), do: {:ok, finalize_machine(machine)}

  defp parse_lines([line | rest], machine) do
    cond do
      Regex.match?(@note_start, line) ->
        parse_note(rest, machine, line)

      Regex.match?(@state_declaration, line) ->
        case parse_state_declaration(line) do
          {:ok, state} -> parse_lines(rest, put_state(machine, state))
          {:error, reason} -> {:error, reason}
        end

      Regex.match?(@transition_declaration, line) ->
        case parse_transition(line, machine) do
          {:ok, updated_machine} -> parse_lines(rest, updated_machine)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, {:unsupported_mermaid_line, line}}
    end
  end

  defp parse_note(lines, machine, line) do
    %{"id" => state_id} = Regex.named_captures(@note_start, line)
    {note_lines, rest} = Enum.split_while(lines, &(&1 != "end note"))

    case rest do
      ["end note" | remaining] ->
        updated_machine =
          machine
          |> ensure_state(state_id)
          |> update_state_metadata(state_id, note_lines)

        parse_lines(remaining, updated_machine)

      _ ->
        {:error, {:unterminated_note, state_id}}
    end
  end

  defp parse_transition(line, machine) do
    captures = Regex.named_captures(@transition_declaration, line)
    source = normalize_source(captures["source"])
    target = normalize_target(captures["target"])
    label = normalize_optional_string(captures["label"] || "")

    cond do
      source == :start and target == StateMachine.end_state_id() ->
        {:error, {:invalid_initial_transition, line}}

      source == :start and not is_nil(label) ->
        {:error, {:invalid_initial_transition_metadata, line}}

      source == :start ->
        case machine.initial_state do
          nil -> {:ok, ensure_state(%{machine | initial_state: target}, target)}
          _ -> {:error, {:duplicate_initial_transition, line}}
        end

      true ->
        transition = build_transition(source, target, label)

        updated_machine =
          machine
          |> ensure_state(source)
          |> ensure_state(target)
          |> Map.update!(:transitions, &(&1 ++ [transition]))

        {:ok, updated_machine}
    end
  end

  defp build_transition(source, target, nil) do
    %Transition{source: source, target: target}
  end

  defp build_transition(source, target, label) do
    annotations = Regex.scan(@annotation, label, capture: :all_but_first)
    stripped_event = Regex.replace(@annotation, label, "") |> String.trim()

    {metadata, actions, condition} =
      Enum.reduce(annotations, {%{}, [], nil}, fn [key, value], {metadata, actions, condition} ->
        normalized_value = String.trim(value)

        case key do
          "condition" -> {metadata, actions, normalized_value}
          "action" -> {metadata, actions ++ [normalized_value], condition}
          "actions" -> {metadata, actions ++ split_csv(normalized_value), condition}
          _ -> {Map.put(metadata, key, parse_scalar(normalized_value)), actions, condition}
        end
      end)

    event =
      case stripped_event do
        "" -> nil
        value -> value
      end

    %Transition{
      source: source,
      target: target,
      event: event,
      condition: condition,
      actions: actions,
      metadata: metadata
    }
  end

  defp normalize_source("[*]"), do: :start
  defp normalize_source(value), do: value

  defp normalize_target("[*]"), do: StateMachine.end_state_id()
  defp normalize_target(value), do: value

  defp build_state(id, label), do: %State{id: id, label: label}

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp update_state_metadata(machine, state_id, note_lines) do
    state = Map.fetch!(machine.states, state_id)

    {activities, metadata} =
      Enum.reduce(note_lines, {state.activities, state.metadata}, fn line, {activities, metadata} ->
        case String.split(line, ":", parts: 2) do
          [raw_key, raw_value] ->
            key = String.trim(raw_key)
            value = String.trim(raw_value)

            case key do
              "activity" -> {activities ++ [value], metadata}
              _ -> {activities, Map.put(metadata, key, parse_scalar(value))}
            end

          _ ->
            {activities, Map.update(metadata, "note", line, &(&1 <> "\n" <> line))}
        end
      end)

    replace_state(machine, %{state | activities: activities, metadata: metadata})
  end

  defp ensure_state(machine, state_id) when state_id == @end_state_id, do: machine

  defp ensure_state(machine, state_id) do
    if Map.has_key?(machine.states, state_id) do
      machine
    else
      put_state(machine, %State{id: state_id, label: state_id})
    end
  end

  defp put_state(machine, %State{id: state_id} = state) do
    %{machine | states: Map.put(machine.states, state_id, merge_state(Map.get(machine.states, state_id), state))}
  end

  defp replace_state(machine, %State{id: state_id} = state) do
    %{machine | states: Map.put(machine.states, state_id, state)}
  end

  defp merge_state(nil, state), do: state

  defp merge_state(existing, incoming) do
    %State{
      id: incoming.id || existing.id,
      label: incoming.label || existing.label,
      activities: existing.activities ++ incoming.activities,
      metadata: Map.merge(existing.metadata, incoming.metadata)
    }
  end

  defp finalize_machine(machine) do
    case machine.initial_state do
      nil -> machine
      initial_state -> ensure_state(machine, initial_state)
    end
  end

  defp parse_scalar("true"), do: true
  defp parse_scalar("false"), do: false

  defp parse_scalar(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp normalize_optional_string(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_state_declaration(line) when is_binary(line) do
    captures = Regex.named_captures(@state_declaration, line)

    case captures do
      %{"simple_id" => id} when is_binary(id) and id != "" ->
        reject_reserved_state_id(id, line, fn -> {:ok, build_state(id, id)} end)

      %{"label" => label, "id" => id} when is_binary(id) and id != "" ->
        reject_reserved_state_id(id, line, fn -> {:ok, build_state(id, label)} end)
    end
  end

  defp reject_reserved_state_id(@end_state_id, line, _builder),
    do: {:error, {:reserved_state_id, @end_state_id, line}}

  defp reject_reserved_state_id(_id, _line, builder), do: builder.()
end
