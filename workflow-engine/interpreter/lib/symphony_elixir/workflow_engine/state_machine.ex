defmodule SymphonyElixir.WorkflowEngine.StateMachine do
  @moduledoc """
  Internal representation for Mermaid-backed workflow state machines.
  """

  @end_state_id "__end__"

  defstruct id: "workflow",
            title: nil,
            initial_state: nil,
            states: %{},
            transitions: [],
            metadata: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          initial_state: String.t() | nil,
          states: %{optional(String.t()) => __MODULE__.State.t()},
          transitions: [__MODULE__.Transition.t()],
          metadata: map()
        }

  @spec end_state_id() :: String.t()
  def end_state_id, do: @end_state_id

  defmodule State do
    @moduledoc """
    Parsed workflow state.
    """

    defstruct id: nil,
              label: nil,
              activities: [],
              metadata: %{}

    @type t :: %__MODULE__{
            id: String.t() | nil,
            label: String.t() | nil,
            activities: [String.t()],
            metadata: map()
          }
  end

  defmodule Transition do
    @moduledoc """
    Ordered edge between two states.
    """

    defstruct source: nil,
              target: nil,
              event: nil,
              condition: nil,
              actions: [],
              metadata: %{}

    @type t :: %__MODULE__{
            source: String.t() | nil,
            target: String.t() | nil,
            event: String.t() | nil,
            condition: String.t() | nil,
            actions: [String.t()],
            metadata: map()
          }
  end
end
