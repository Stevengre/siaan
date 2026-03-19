defmodule SymphonyElixir.WorkflowEngine.Validator do
  @moduledoc """
  Analyzes workflow graphs for structural execution risks.
  """

  alias SymphonyElixir.WorkflowEngine.StateMachine
  @end_state_id StateMachine.end_state_id()

  @spec analyze(StateMachine.t()) :: map()
  def analyze(%StateMachine{} = machine) do
    reachable = reachable_states(machine)
    state_ids = Map.keys(machine.states) |> MapSet.new()

    invalid_transitions =
      Enum.flat_map(machine.transitions, fn transition ->
        []
        |> maybe_add_invalid_state(:unknown_transition_source, transition.source, state_ids)
        |> maybe_add_invalid_state(:unknown_transition_target, transition.target, state_ids)
      end)

    unreachable =
      state_ids
      |> MapSet.delete(StateMachine.end_state_id())
      |> MapSet.difference(reachable)
      |> MapSet.to_list()
      |> Enum.sort()

    deadlocks =
      machine.states
      |> Enum.reject(fn {state_id, state} -> terminal_state?(state) or state_id == StateMachine.end_state_id() end)
      |> Enum.filter(fn {state_id, _state} -> outgoing_transitions(machine, state_id) == [] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    missing_conditions =
      machine.transitions
      |> Enum.filter(fn transition ->
        branching_transition?(machine, transition.source) and blank?(transition.condition)
      end)
      |> Enum.map(fn transition -> %{source: transition.source, target: transition.target} end)

    findings =
      invalid_transitions ++
        Enum.map(unreachable, &{:unreachable_state, &1}) ++
        Enum.map(deadlocks, &{:deadlock_state, &1}) ++
        Enum.map(missing_conditions, &{:missing_condition, &1})

    %{
      valid?: findings == [] and not is_nil(machine.initial_state),
      initial_state: machine.initial_state,
      reachable_states: reachable |> MapSet.to_list() |> Enum.sort(),
      unreachable_states: unreachable,
      deadlocks: deadlocks,
      missing_conditions: missing_conditions,
      findings: maybe_prepend_missing_initial_state(findings, machine.initial_state)
    }
  end

  @spec validate(StateMachine.t()) :: :ok | {:error, [term()]}
  def validate(%StateMachine{} = machine) do
    analysis = analyze(machine)

    case analysis.findings do
      [] when not is_nil(machine.initial_state) -> :ok
      findings -> {:error, findings}
    end
  end

  defp reachable_states(%StateMachine{initial_state: nil}), do: MapSet.new()

  defp reachable_states(%StateMachine{} = machine) do
    do_reachable(machine, MapSet.new([machine.initial_state]), [machine.initial_state])
  end

  defp do_reachable(_machine, visited, []), do: visited

  defp do_reachable(machine, visited, [state_id | rest]) do
    next_states =
      machine
      |> outgoing_transitions(state_id)
      |> Enum.map(& &1.target)
      |> Enum.reject(&(&1 == StateMachine.end_state_id()))
      |> Enum.reject(&MapSet.member?(visited, &1))

    visited = Enum.reduce(next_states, visited, &MapSet.put(&2, &1))
    do_reachable(machine, visited, rest ++ next_states)
  end

  defp outgoing_transitions(machine, state_id) do
    Enum.filter(machine.transitions, &(&1.source == state_id))
  end

  defp maybe_add_invalid_state(findings, _type, state_id, _state_ids) when state_id == @end_state_id, do: findings

  defp maybe_add_invalid_state(findings, type, state_id, state_ids) do
    if MapSet.member?(state_ids, state_id) do
      findings
    else
      findings ++ [{type, state_id}]
    end
  end

  defp branching_transition?(machine, source) do
    machine
    |> outgoing_transitions(source)
    |> length()
    |> Kernel.>(1)
  end

  defp terminal_state?(state) do
    Map.get(state.metadata, "terminal", false) == true
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp maybe_prepend_missing_initial_state(findings, nil), do: [{:missing_initial_state, nil} | findings]
  defp maybe_prepend_missing_initial_state(findings, _initial_state), do: findings
end
