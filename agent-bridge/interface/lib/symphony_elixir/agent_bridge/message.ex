defmodule SymphonyElixir.AgentBridge.Message do
  @moduledoc """
  Shared streamed message helper for bridge implementations.
  """

  @type t :: %{
          required(:event) => atom(),
          required(:timestamp) => DateTime.t(),
          optional(atom()) => term()
        }

  @spec build(atom(), map(), map()) :: t()
  def build(event, details, metadata)
      when is_atom(event) and is_map(details) and is_map(metadata) do
    metadata
    |> Map.merge(details)
    |> Map.put(:event, event)
    |> Map.put(:timestamp, DateTime.utc_now())
  end
end
