---
name: gh-issue-triage
description: Triages GitHub issues into a human-reviewable state. Use when a new issue is created or an existing issue lacks clear classification, acceptance criteria, risks, or next steps.
---

# Issue Triage Skill

## Overview
This skill guides the agent to triage new issues, ensuring that each issue has enough information and structure for a human owner to decide whether the work is ready to start. The agent will gather missing details, propose labels (type, priority, area), outline acceptance criteria, and highlight risks and dependencies. The agent **does not** assign a `ready` status; final judgment belongs to a human.

## Reference
Before starting, load the issue management configuration for label taxonomy, status flow, and collaboration rules:
`!cat skills/gh-issue-config/SKILL.md`

## When to use
Invoke this skill whenever a new issue is created or an existing issue lacks clarity or classification. The triage step happens **before** any execution or code changes take place.

## Steps
1. **Parse the issue**
   - Read the issue title, description, and any attachments or comments.
   - Summarize the problem or goal in your own words, clarifying context and objectives.

2. **Classify the issue**
   - Determine if it is a bug, feature, task, research, or epic.
   - If classification is ambiguous, ask clarifying questions in the issue comments. Do not guess.

3. **Assess priority**
   - Suggest a priority (`priority:p0` / `priority:p1` / `priority:p2`) based on severity, impact, urgency, or value.
   - Provide one sentence of reasoning.

4. **Identify area and kind**
   - Suggest the most relevant `area:*` label so that work can be filtered.
   - Multiple areas are acceptable only when the work is truly cross-cutting.
   - If applicable, suggest one `kind:*` label (`kind:refactor`, `kind:perf`, `kind:test`, `kind:docs`).

5. **Verify minimum labeling**
   - Ensure the issue will have at least: one `type:*`, one `status:*` (defaults to `status:triage`), one `priority:*`, and usually one `area:*`.
   - Flag any missing labels explicitly.

6. **Gather missing information**
   - List questions that need answers before work can start, such as design decisions, dependencies, environment details, scope boundaries, or user expectations.
   - If the issue lacks a clear goal or acceptance criteria, draft a possible acceptance checklist. Each criterion must be specific and testable.

7. **Outline risks and dependencies**
   - Note obvious blockers, dependencies on other issues, or risks that might affect scheduling or implementation.

8. **Set issue relationships via GitHub GraphQL API**
   - Fetch all open issues and their IDs with:
     ```
     gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issues(first: 50, states: OPEN) { nodes { number id title } } } }'
     ```
   - Analyze the new issue's content against existing issues to determine:
     - Is this issue **blocked by** another? (cannot start until that one is done)
     - Is this issue **blocking** another? (that one cannot start until this is done)
   - For each identified relationship, apply it immediately using the GraphQL mutation:
     - `addBlockedBy(input: { issueId: "<blocked_issue_id>", blockingIssueId: "<blocker_id>" })`
   - Only set relationships with clear, content-based justification. Do not infer from vague overlap.
   - Report which relationships were set (e.g., "Set #4 as blocked by #1").

9. **Reorder parent epic's sub-issues**
   - If this issue belongs to a parent epic (check `parent` field), reorder the epic's sub-issues so that looking top-to-bottom gives the correct execution order.
   - Fetch the epic's sub-issues, their `blockedBy`/`blocking` relationships, `status:*`, and `priority:*` labels.
   - Sort by: topological order (dependencies first) → priority (p0 > p1 > p2) → critical-path preference (an issue that unblocks a high-priority issue should come earlier, even if its own priority is lower).
   - Apply the order using GraphQL mutations:
     ```
     reprioritizeSubIssue(input: { issueId: "<epic_id>", subIssueId: "<child_id>", afterId: "<previous_child_id>" })
     ```
     Use `beforeId` instead of `afterId` when placing an issue first.
   - Skip this step if the issue has no parent epic.

10. **Propose a minimal plan**
   - If the issue is non-trivial, draft a simple work breakdown of the major tasks needed to complete it.
   - Do not write code.

11. **Output a triage summary**
   - Restate the summary, classification, priority, and area.
   - Present the proposed acceptance criteria, risks, dependencies, and plan.
   - End with this notice:

     `Human review required before status:ready. Do not begin execution until a human approves and sets the issue to ready.`

12. **Self-improvement**
   - When triage results are approved or corrected, update internal triage guidelines.
   - Capture examples of well-triaged issues and common mistakes.
   - Never delete past guidelines; append lessons learned.

## Do Not
- Do not mark the issue as `ready` or change the issue status yourself.
- Do not assign tasks to specific people.
- Do not remove or override human labels or comments.
- Do not begin any code execution or changes.
