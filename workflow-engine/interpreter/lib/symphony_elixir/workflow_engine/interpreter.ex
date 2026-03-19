defmodule SymphonyElixir.WorkflowEngine.Interpreter do
  @moduledoc """
  Executes a parsed workflow machine by evaluating ordered transitions.
  """

  alias SymphonyElixir.WorkflowEngine.StateMachine
  alias SymphonyElixir.WorkflowEngine.StateMachine.Transition
  @end_state_id StateMachine.end_state_id()

  defmodule Runtime do
    @moduledoc """
    Mutable execution snapshot for a workflow machine.
    """

    defstruct machine: nil,
              current_state: nil,
              context: %{},
              history: [],
              halted: false

    @type t :: %__MODULE__{
            machine: StateMachine.t() | nil,
            current_state: String.t() | nil,
            context: map(),
            history: [map()],
            halted: boolean()
          }
  end

  @type resolver :: (String.t(), map() -> boolean() | {:ok, boolean()} | {:error, term()} | :ok | {:ok, map()})

  @spec start(StateMachine.t(), keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  def start(machine, opts \\ [])

  def start(%StateMachine{initial_state: nil}, _opts), do: {:error, :missing_initial_state}

  def start(%StateMachine{} = machine, opts) when is_list(opts) do
    runtime = %Runtime{
      machine: machine,
      current_state: machine.initial_state,
      context: Keyword.get(opts, :context, %{})
    }

    enter_state(runtime, machine.initial_state, opts)
  end

  @spec advance(Runtime.t(), keyword()) ::
          {:transitioned, Runtime.t(), Transition.t()} | {:stalled, Runtime.t(), [term()]} | {:error, term()}
  def advance(runtime, opts \\ [])

  def advance(%Runtime{halted: true} = runtime, _opts), do: {:stalled, runtime, [:halted]}

  def advance(%Runtime{} = runtime, opts) when is_list(opts) do
    outgoing = outgoing_transitions(runtime.machine, runtime.current_state)
    evaluator = Keyword.get(opts, :condition_evaluator, &default_condition_evaluator/2)

    case select_transition(outgoing, runtime.context, evaluator) do
      {:ok, nil, reasons} ->
        {:stalled, runtime, reasons}

      {:ok, transition, _reasons} ->
        with {:ok, context} <- run_actions(transition.actions, runtime.context, Keyword.get(opts, :action_runner, &default_effect_runner/2)),
             {:ok, runtime} <- enter_target(runtime, transition, context, opts) do
          {:transitioned, runtime, transition}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run(StateMachine.t(), keyword()) :: {:ok, Runtime.t()} | {:error, term()}
  def run(%StateMachine{} = machine, opts \\ []) when is_list(opts) do
    with {:ok, runtime} <- start(machine, opts) do
      do_run(runtime, opts)
    end
  end

  defp do_run(%Runtime{halted: true} = runtime, _opts), do: {:ok, runtime}

  defp do_run(runtime, opts) do
    case advance(runtime, opts) do
      {:transitioned, next_runtime, _transition} -> do_run(next_runtime, opts)
      {:stalled, stalled_runtime, _reasons} -> {:ok, stalled_runtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp outgoing_transitions(machine, state_id) do
    Enum.filter(machine.transitions, &(&1.source == state_id))
  end

  defp select_transition(transitions, context, evaluator) do
    Enum.reduce_while(transitions, {:ok, nil, []}, fn transition, {:ok, nil, reasons} ->
      case evaluate_condition(transition.condition, context, evaluator) do
        {:ok, true} -> {:halt, {:ok, transition, reasons}}
        {:ok, false} -> {:cont, {:ok, nil, reasons ++ [{transition.target, :condition_failed, transition.condition}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_condition(nil, _context, _evaluator), do: {:ok, true}

  defp evaluate_condition(condition, context, evaluator) do
    case evaluator.(condition, context) do
      true -> {:ok, true}
      false -> {:ok, false}
      {:ok, boolean} when is_boolean(boolean) -> {:ok, boolean}
      {:error, reason} -> {:error, {:condition_evaluation_failed, condition, reason}}
      other -> {:error, {:invalid_condition_result, condition, other}}
    end
  end

  defp enter_target(runtime, %Transition{target: target} = transition, context, _opts) when target == @end_state_id do
    updated_runtime = %{
      runtime
      | current_state: target,
        context: context,
        halted: true,
        history: runtime.history ++ [%{type: :transition, transition: transition}, %{type: :halt, state: target}]
    }

    {:ok, updated_runtime}
  end

  defp enter_target(runtime, %Transition{} = transition, context, opts) do
    transition_runtime = %{runtime | context: context, history: runtime.history ++ [%{type: :transition, transition: transition}]}
    enter_state(transition_runtime, transition.target, opts)
  end

  defp enter_state(%Runtime{} = runtime, state_id, opts) do
    state = Map.fetch!(runtime.machine.states, state_id)
    runner = Keyword.get(opts, :activity_runner, &default_effect_runner/2)

    with {:ok, context} <- run_actions(state.activities, runtime.context, runner) do
      {:ok,
       %{
         runtime
         | current_state: state_id,
           context: context,
           history: runtime.history ++ [%{type: :enter, state: state_id, activities: state.activities}]
       }}
    end
  end

  defp run_actions(actions, context, runner) do
    Enum.reduce_while(actions, {:ok, context}, fn action, {:ok, acc} ->
      case runner.(action, acc) do
        :ok -> {:cont, {:ok, acc}}
        {:ok, %{} = updated_context} -> {:cont, {:ok, updated_context}}
        {:error, reason} -> {:halt, {:error, {:effect_failed, action, reason}}}
        other -> {:halt, {:error, {:invalid_effect_result, action, other}}}
      end
    end)
  end

  defp default_condition_evaluator(_condition, _context), do: {:error, :missing_condition_evaluator}
  defp default_effect_runner(_effect, context), do: {:ok, context}
end
