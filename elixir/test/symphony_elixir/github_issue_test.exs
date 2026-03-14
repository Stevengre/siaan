defmodule SymphonyElixir.GitHub.IssueTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Issue

  test "label helper normalizes and filters labels" do
    issue = %Issue{labels: [" Status:Ready ", "", nil, "Infra"]}

    assert Issue.label_names(issue) == ["status:ready", "infra"]
    assert Issue.status_label(issue) == "status:ready"
  end

  test "to_tracker_issue handles binary and missing numbers" do
    issue_with_binary_number = %Issue{
      id: "17",
      number: "17",
      title: "Binary number",
      body: "Description",
      state: "status:review",
      url: "https://github.com/acme/repo/issues/17",
      labels: ["status:review"],
      assignees: ["octocat"]
    }

    converted = Issue.to_tracker_issue(issue_with_binary_number)
    assert converted.identifier == "GH-17"
    assert converted.assignee_id == "octocat"

    issue_without_number = %Issue{id: "18", number: nil, labels: ["status:ready"], assignees: []}
    converted_without_number = Issue.to_tracker_issue(issue_without_number)

    assert converted_without_number.identifier == nil
    assert converted_without_number.assignee_id == nil
  end
end
