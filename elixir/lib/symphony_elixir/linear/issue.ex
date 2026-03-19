defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Deprecated alias for the tracker issue model retained for compatibility.
  """

  defdelegate label_names(issue), to: SymphonyElixir.StateSync.Issue
end
