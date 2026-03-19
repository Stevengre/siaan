defmodule SymphonyElixir.StateSync.GitHub.MergeAutomation.AutoMerge do
  @moduledoc """
  GitHub merge automation helpers kept outside the shared state sync boundary.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.StateSync.GitHub.Client

  @type readiness_result ::
          {:ok, :ready, pos_integer()} | {:ok, :needs_agent, [String.t()]} | {:error, term()}

  @spec check_readiness(String.t()) :: readiness_result()
  def check_readiness(issue_id) when is_binary(issue_id) do
    case Config.settings!().state.type do
      "github" -> client_module().check_auto_merge_readiness(issue_id)
      _ -> {:ok, :needs_agent, ["unsupported tracker"]}
    end
  end

  @spec check_readiness_for_test(String.t(), Client.request_fun()) :: readiness_result()
  def check_readiness_for_test(issue_id, request_fun)
      when is_binary(issue_id) and is_function(request_fun, 3) do
    client_module().check_auto_merge_readiness_for_test(issue_id, request_fun)
  end

  @spec merge_pull_request(pos_integer()) :: :ok | {:error, term()}
  def merge_pull_request(pr_number) when is_integer(pr_number) do
    case Config.settings!().state.type do
      "github" -> client_module().auto_merge_pr(pr_number)
      _ -> {:error, :unsupported_tracker}
    end
  end

  @spec merge_pull_request_for_test(pos_integer(), Client.request_fun()) :: :ok | {:error, term()}
  def merge_pull_request_for_test(pr_number, request_fun)
      when is_integer(pr_number) and is_function(request_fun, 3) do
    client_module().auto_merge_pr_for_test(pr_number, request_fun)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
