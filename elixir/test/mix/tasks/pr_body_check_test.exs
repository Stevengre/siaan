defmodule Mix.Tasks.PrBody.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrBody.Check

  import ExUnit.CaptureIO

  @template """
  ### Behavior Delta

  | | Before | After |
  |---|---|---|
  | Trigger | ... | ... |

  ### Invariants / Non-goals

  - **Must still hold**: ...
  - **Explicitly unchanged**: ...
  - **Out of scope**: ...

  ### Validation

  | Risk point | Evidence | Link |
  |---|---|---|
  | ... | ... | ... |

  ### Risk / Blast Radius / Rollback

  - **Most likely failure**: ...
  - **Blast radius**: ...
  - **How to detect**: ...
  - **How to rollback**: ...

  ### Review Focus

  1. ...

  <details>
  <summary><b>Architecture Trace</b></summary>

  ### Context (C4-L1)

  No L1 change.

  ### Container (C4-L2)

  Single container change.

  ### Component (C4-L3)

  One component participates.

  ### Code Trace (C4-L4)

  - Component -> function -> link

  ### Decision Record

  - **Decision**: ...
  - **Alternatives considered**: ...
  - **Trade-offs**: ...
  - **Why chosen**: ...
  - **Implementation links**: ...

  </details>
  """

  @valid_body """
  ### Behavior Delta

  | | Before | After |
  |---|---|---|
  | Trigger | Manual PR authoring | Agent-generated PR descriptions from issue + diff |
  | Observable effect | Reviewers infer correctness from prose | Reviewers get explicit behavior delta, invariants, evidence, and rollback notes |
  | Affected inputs | Any PR body with the legacy headings | PR bodies matching the Change Proof + Architecture Trace template |

  ```mermaid
  sequenceDiagram
    reviewer->>pr: read Change Proof
    pr->>reviewer: answer the approval questions
  ```

  ### Invariants / Non-goals

  - **Must still hold**: PR descriptions remain markdown-only and GitHub-renderable.
  - **Explicitly unchanged**: The validator still runs through `mix pr_body.check`.
  - **Out of scope**: Auto-linking evidence artifacts that do not already exist in the PR.

  ### Validation

  | Risk point | Evidence | Link |
  |---|---|---|
  | Missing Change Proof sections | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |
  | Invalid appendix structure | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |

  ### Risk / Blast Radius / Rollback

  - **Most likely failure**: A PR body copies the headings but omits real evidence.
  - **Blast radius**: PR authoring guidance, local PR body linting, and PR-description CI.
  - **How to detect**: `mix pr_body.check` or the `validate-pr-description` GitHub check fails.
  - **How to rollback**: Revert the template + validator changes.

  ### Review Focus

  1. Confirm the lint task enforces the new approval-oriented structure.
  2. Verify the PR template keeps the appendix in `<details>` with all required C4 headings.
  3. Check that the skill instructions handle multi-change PRs and pure refactors.

  <details>
  <summary><b>Architecture Trace</b></summary>

  ### Context (C4-L1)

  No L1 change - this PR only changes repository automation/tooling guidance and validation.

  ### Container (C4-L2)

  Single-container change within the repository automation/tooling path.

  ### Component (C4-L3)

  The PR template, PR-body validator, and agent skills now align on the same reviewer-facing structure.

  ```mermaid
  flowchart TD
    Skill --> Template
    Template --> Validator
  ```

  ### Code Trace (C4-L4)

  - PR body validator -> `Mix.Tasks.PrBody.Check` -> `/elixir/lib/mix/tasks/pr_body.check.ex`
  - Codex skill -> `pr-description` -> `/.codex/skills/pr-description/SKILL.md`

  ### Decision Record

  - **Decision**: Make `mix pr_body.check` enforce the approval-oriented sections directly.
  - **Alternatives considered**: Keep the validator generic and rely on template-only guidance.
  - **Trade-offs**: Slightly more code in the lint task, but stronger reviewer-confidence guarantees.
  - **Why chosen**: The ticket requires the check to reference the new sections, not just arbitrary headings.
  - **Implementation links**: `/elixir/lib/mix/tasks/pr_body.check.ex`, `/.github/PULL_REQUEST_TEMPLATE.md`

  </details>
  """

  setup do
    Mix.Task.reenable("pr_body.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> Check.run(["--help"]) end)
    assert output =~ "mix pr_body.check --file /path/to/pr_body.md"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["lint", "--wat"])
    end
  end

  test "fails when file option is missing" do
    assert_raise Mix.Error, ~r/Missing required option --file/, fn ->
      Check.run(["lint"])
    end
  end

  test "fails when template is missing" do
    in_temp_repo(fn ->
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/Unable to read PR template/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when template has no headings" do
    in_temp_repo(fn ->
      write_template!("no headings here")
      File.write!("body.md", @valid_body)

      assert_raise Mix.Error, ~r/No markdown headings found/, fn ->
        Check.run(["lint", "--file", "body.md"])
      end
    end)
  end

  test "fails when body file is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      assert_raise Mix.Error, ~r/Unable to read missing\.md/, fn ->
        Check.run(["lint", "--file", "missing.md"])
      end
    end)
  end

  test "fails when body still has placeholders" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body <> "\n<!-- placeholder -->\n")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "PR description still contains template placeholder comments"
    end)
  end

  test "fails when heading is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      missing_heading =
        String.replace(
          @valid_body,
          "### Validation\n\n| Risk point | Evidence | Link |\n|---|---|---|\n| Missing Change Proof sections | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |\n| Invalid appendix structure | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |\n\n",
          ""
        )

      File.write!("body.md", missing_heading)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Missing required heading: ### Validation"
    end)
  end

  test "fails when headings are out of order" do
    in_temp_repo(fn ->
      write_template!(@template)

      out_of_order = """
      ### Invariants / Non-goals

      - **Must still hold**: Still true.
      - **Explicitly unchanged**: Also true.
      - **Out of scope**: Not changing.

      ### Behavior Delta

      | | Before | After |
      |---|---|---|
      | Trigger | Before | After |

      ### Validation

      | Risk point | Evidence | Link |
      |---|---|---|
      | Risk | Test | N/A |

      ### Risk / Blast Radius / Rollback

      - **Most likely failure**: Something.
      - **Blast radius**: Scoped.
      - **How to detect**: Check fails.
      - **How to rollback**: Revert.

      ### Review Focus

      1. Review it.

      <details>
      <summary><b>Architecture Trace</b></summary>

      ### Context (C4-L1)

      No L1 change.

      ### Container (C4-L2)

      Single container.

      ### Component (C4-L3)

      Component details.

      ### Code Trace (C4-L4)

      - Link

      ### Decision Record

      No design decision introduced in this PR.

      </details>
      """

      File.write!("body.md", out_of_order)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Required headings are out of order."
    end)
  end

  test "fails on empty section" do
    in_temp_repo(fn ->
      write_template!(@template)

      empty_context =
        String.replace(
          @valid_body,
          "No L1 change - this PR only changes repository automation/tooling guidance and validation.",
          ""
        )

      File.write!("body.md", empty_context)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: ### Context (C4-L1)"
    end)
  end

  test "fails when a middle section is blank before the next heading" do
    in_temp_repo(fn ->
      write_template!(@template)

      blank_section = """
      ### Behavior Delta

      | | Before | After |
      |---|---|---|
      | Trigger | Before | After |

      ### Invariants / Non-goals

      - **Must still hold**: Still true.
      - **Explicitly unchanged**: Also true.
      - **Out of scope**: Not changing.

      ### Validation

      | Risk point | Evidence | Link |
      |---|---|---|
      | Risk | Test | N/A |

      ### Risk / Blast Radius / Rollback


      ### Review Focus

      1. Review it.

      <details>
      <summary><b>Architecture Trace</b></summary>

      ### Context (C4-L1)

      No L1 change.

      ### Container (C4-L2)

      Single container.

      ### Component (C4-L3)

      Component details.

      ### Code Trace (C4-L4)

      - Link

      ### Decision Record

      No design decision introduced in this PR.

      </details>
      """

      File.write!("body.md", blank_section)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: ### Risk / Blast Radius / Rollback"
    end)
  end

  test "fails when behavior delta does not include a table" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body =
        String.replace(
          @valid_body,
          "| | Before | After |\n|---|---|---|\n| Trigger | Manual PR authoring | Agent-generated PR descriptions from issue + diff |\n| Observable effect | Reviewers infer correctness from prose | Reviewers get explicit behavior delta, invariants, evidence, and rollback notes |\n| Affected inputs | Any PR body with the legacy headings | PR bodies matching the Change Proof + Architecture Trace template |",
          "No behavior table."
        )

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include a markdown table with at least one data row: ### Behavior Delta"
    end)
  end

  test "fails when validation does not include a table" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body =
        String.replace(
          @valid_body,
          "| Risk point | Evidence | Link |\n|---|---|---|\n| Missing Change Proof sections | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |\n| Invalid appendix structure | test: `mix test test/mix/tasks/pr_body_check_test.exs` | N/A (local command) |",
          "- no table here"
        )

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include a markdown table with at least one data row: ### Validation"
    end)
  end

  test "fails when template bullet requirements are not met" do
    in_temp_repo(fn ->
      template = """
      #### Summary

      - <!-- Summary bullet -->
      """

      invalid_body = """
      #### Summary

      Not a bullet.
      """

      write_template!(template)
      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include at least one bullet item: #### Summary"
    end)
  end

  test "fails when template checkbox requirements are not met" do
    in_temp_repo(fn ->
      template = """
      #### Test Plan

      - [ ] <!-- Test checkbox -->
      """

      invalid_body = """
      #### Test Plan

      No checkbox.
      """

      write_template!(template)
      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include at least one bullet item: #### Test Plan"
      assert error_output =~ "Section must include at least one checkbox item: #### Test Plan"
    end)
  end

  test "fails when review focus is not numbered" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body =
        String.replace(
          @valid_body,
          "1. Confirm the lint task enforces the new approval-oriented structure.\n2. Verify the PR template keeps the appendix in `<details>` with all required C4 headings.\n3. Check that the skill instructions handle multi-change PRs and pure refactors.",
          "- Confirm the lint task enforces the new approval-oriented structure.\n- Verify the PR template keeps the appendix in `<details>` with all required C4 headings.\n- Check that the skill instructions handle multi-change PRs and pure refactors."
        )

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section must include a numbered list: ### Review Focus"
    end)
  end

  test "fails when architecture trace details wrapper is missing" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body = String.replace(@valid_body, "<details>", "<section>")
      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Architecture Trace appendix must be wrapped in <details>."
    end)
  end

  test "fails when decision record omits alternatives and trade-offs" do
    in_temp_repo(fn ->
      write_template!(@template)

      invalid_body =
        String.replace(
          @valid_body,
          "- **Decision**: Make `mix pr_body.check` enforce the approval-oriented sections directly.\n- **Alternatives considered**: Keep the validator generic and rely on template-only guidance.\n- **Trade-offs**: Slightly more code in the lint task, but stronger reviewer-confidence guarantees.\n- **Why chosen**: The ticket requires the check to reference the new sections, not just arbitrary headings.\n- **Implementation links**: `/elixir/lib/mix/tasks/pr_body.check.ex`, `/.github/PULL_REQUEST_TEMPLATE.md`",
          "- **Decision**: Just do it."
        )

      File.write!("body.md", invalid_body)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~
               "Decision Record must either say `No design decision introduced in this PR.` or include Decision, Alternatives considered, Trade-offs, Why chosen, and Implementation links."
    end)
  end

  test "accepts the no-decision record form" do
    in_temp_repo(fn ->
      write_template!(@template)

      valid_body =
        String.replace(
          @valid_body,
          "- **Decision**: Make `mix pr_body.check` enforce the approval-oriented sections directly.\n- **Alternatives considered**: Keep the validator generic and rely on template-only guidance.\n- **Trade-offs**: Slightly more code in the lint task, but stronger reviewer-confidence guarantees.\n- **Why chosen**: The ticket requires the check to reference the new sections, not just arbitrary headings.\n- **Implementation links**: `/elixir/lib/mix/tasks/pr_body.check.ex`, `/.github/PULL_REQUEST_TEMPLATE.md`",
          "No design decision introduced in this PR."
        )

      File.write!("body.md", valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  test "fails when heading has no content delimiter" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "### Behavior Delta\nNo separator.")

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
          Check.run(["lint", "--file", "body.md"])
        end
      end)
    end)
  end

  test "fails when heading appears at end of file" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", "### Behavior Delta")

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/PR body format invalid/, fn ->
            Check.run(["lint", "--file", "body.md"])
          end
        end)

      assert error_output =~ "Section cannot be empty: ### Behavior Delta"
    end)
  end

  test "passes for valid body" do
    in_temp_repo(fn ->
      write_template!(@template)
      File.write!("body.md", @valid_body)

      output =
        capture_io(fn ->
          Check.run(["lint", "--file", "body.md"])
        end)

      assert output =~ "PR body format OK"
    end)
  end

  defp in_temp_repo(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "validate-pr-body-task-test-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp write_template!(content) do
    File.mkdir_p!(".github")
    File.write!(".github/PULL_REQUEST_TEMPLATE.md", content)
  end
end
