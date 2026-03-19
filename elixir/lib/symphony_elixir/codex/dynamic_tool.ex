defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Compatibility wrapper for the extracted Codex dynamic-tool implementation.
  """

  alias SymphonyElixir.AgentBridge.Codex.DynamicTool, as: Impl

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  defdelegate execute(tool, arguments, opts \\ []), to: Impl

  @spec tool_specs(keyword()) :: [map()]
  defdelegate tool_specs(opts \\ []), to: Impl
end
