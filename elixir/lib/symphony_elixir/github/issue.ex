defmodule SymphonyElixir.GitHub.Issue do
  @moduledoc """
  Normalized GitHub issue representation used by the GitHub tracker integration.
  """

  alias SymphonyElixir.Linear.Issue, as: TrackerIssue

  defstruct [
    :id,
    :number,
    :title,
    :body,
    :state,
    :url,
    labels: [],
    assignees: [],
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          number: non_neg_integer() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          state: String.t() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          assignees: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec status_label(t()) :: String.t() | nil
  def status_label(%__MODULE__{} = issue) do
    issue
    |> label_names()
    |> Enum.find(&String.starts_with?(&1, "status:"))
  end

  @spec to_tracker_issue(t()) :: TrackerIssue.t()
  def to_tracker_issue(%__MODULE__{} = issue) do
    labels = label_names(issue)

    %TrackerIssue{
      id: issue.id,
      identifier: issue_identifier(issue.number),
      title: issue.title,
      description: issue.body,
      priority: nil,
      state: issue.state,
      branch_name: nil,
      url: issue.url,
      assignee_id: List.first(issue.assignees),
      blocked_by: [],
      labels: labels,
      assigned_to_worker: true,
      created_at: issue.created_at,
      updated_at: issue.updated_at
    }
  end

  defp issue_identifier(number) when is_integer(number), do: "GH-#{number}"
  defp issue_identifier(number) when is_binary(number), do: "GH-#{number}"
  defp issue_identifier(_number), do: nil

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_label(_label), do: nil
end
