defmodule SymphonyElixir.TrackerIssue do
  @moduledoc """
  Normalized tracker issue representation used by the orchestrator runtime.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :issue_root,
    :issue_slug,
    :issue_path,
    :issue_dir,
    :workpad_path,
    :project_dir,
    :project_runtime,
    :prompt_template_path,
    :base_branch,
    :current_branch,
    blocked_by: [],
    created_at: nil,
    updated_at: nil,
    skill_prompts: [],
    labels: [],
    assigned_to_worker: true
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          issue_root: String.t() | nil,
          issue_slug: String.t() | nil,
          issue_path: String.t() | nil,
          issue_dir: String.t() | nil,
          workpad_path: String.t() | nil,
          project_dir: String.t() | nil,
          project_runtime: String.t() | nil,
          prompt_template_path: String.t() | nil,
          skill_prompts: [map()],
          base_branch: String.t() | nil,
          current_branch: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
