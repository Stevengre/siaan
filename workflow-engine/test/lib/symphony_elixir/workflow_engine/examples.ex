defmodule SymphonyElixir.WorkflowEngine.Examples do
  @moduledoc """
  Shared Mermaid fixtures for workflow engine tests and documentation.
  """

  @external_resource Path.expand("../../../../examples/github_issue_workflow.mmd", __DIR__)
  @external_resource Path.expand("../../../../examples/github_issue_workflow.conditions.yaml", __DIR__)

  @spec github_issue_workflow_diagram() :: String.t()
  def github_issue_workflow_diagram do
    Path.expand("../../../../examples/github_issue_workflow.mmd", __DIR__)
    |> File.read!()
  end

  @spec github_issue_conditions_manifest() :: String.t()
  def github_issue_conditions_manifest do
    Path.expand("../../../../examples/github_issue_workflow.conditions.yaml", __DIR__)
    |> File.read!()
  end

  @spec parser_demo_diagram() :: String.t()
  def parser_demo_diagram do
    """
    stateDiagram-v2
      [*] --> ready

      state "Ready" as ready
      note right of ready
        activity: setup/workpad
        owner: agent
      end note

      state "In Progress" as in_progress
      note right of in_progress
        activity: execution/run
      end note

      ready --> in_progress: dispatch [condition: issue_is_ready] [action: mark_started]
      in_progress --> [*]: finish [condition: done]
    """
  end

  @spec invalid_diagram() :: String.t()
  def invalid_diagram do
    """
    stateDiagram-v2
      [*] --> ready
      ready --> review: missing condition
      ready --> blocked: wait [condition: blocked]
      lonely --> [*]
    """
  end
end
