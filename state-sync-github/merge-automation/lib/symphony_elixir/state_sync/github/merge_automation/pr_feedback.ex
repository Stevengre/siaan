defmodule SymphonyElixir.StateSync.GitHub.MergeAutomation.PRFeedback do
  @moduledoc """
  GitHub PR feedback and approval helpers kept outside the shared state sync boundary.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.StateSync.GitHub.Client

  @spec has_actionable_feedback?(String.t(), [String.t()]) :: {:ok, boolean()} | {:error, term()}
  def has_actionable_feedback?(issue_id, allowlist)
      when is_binary(issue_id) and is_list(allowlist) do
    case Config.settings!().state.type do
      "github" -> client_module().has_actionable_pr_feedback?(issue_id, allowlist)
      _ -> {:ok, false}
    end
  end

  @spec has_actionable_feedback_for_test(String.t(), [String.t()], Client.request_fun()) ::
          {:ok, boolean()} | {:error, term()}
  def has_actionable_feedback_for_test(issue_id, allowlist, request_fun)
      when is_binary(issue_id) and is_list(allowlist) and is_function(request_fun, 3) do
    client_module().has_actionable_pr_feedback_for_test(issue_id, allowlist, request_fun)
  end

  @spec has_approval?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def has_approval?(issue_id) when is_binary(issue_id) do
    case Config.settings!().state.type do
      "github" -> client_module().has_pr_approval?(issue_id)
      _ -> {:ok, false}
    end
  end

  @spec has_approval_for_test(String.t(), Client.request_fun()) :: {:ok, boolean()} | {:error, term()}
  def has_approval_for_test(issue_id, request_fun)
      when is_binary(issue_id) and is_function(request_fun, 3) do
    client_module().has_pr_approval_for_test(issue_id, request_fun)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
