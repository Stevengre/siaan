defmodule SymphonyElixir.AgentBridge.Session do
  @moduledoc """
  Shared bridge session wrapper.
  """

  @enforce_keys [:bridge]
  defstruct [
    :bridge,
    :native,
    :workspace,
    :worker_host,
    :thread_id,
    :physical_session_reuse_decision,
    :physical_session_fallback_reason,
    metadata: %{},
    state: %{}
  ]

  @type t :: %__MODULE__{
          bridge: module(),
          native: term(),
          workspace: Path.t() | nil,
          worker_host: String.t() | nil,
          thread_id: String.t() | nil,
          physical_session_reuse_decision: String.t() | nil,
          physical_session_fallback_reason: String.t() | nil,
          metadata: map(),
          state: map()
        }

  @spec new(module(), map()) :: t()
  def new(bridge, attrs \\ %{}) when is_atom(bridge) and is_map(attrs) do
    struct!(__MODULE__, Map.put(attrs, :bridge, bridge))
  end
end
