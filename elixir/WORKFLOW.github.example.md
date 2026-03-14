---
tracker:
  kind: github
  api_key: $GITHUB_TOKEN
  repo_owner: "your-org-or-user"
  repo_name: "your-repo"
  ready_label: "status:ready"
  active_states:
    - "status:ready"
    - "status:in-progress"
  terminal_states:
    - "closed"
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 "https://github.com/your-org-or-user/your-repo.git" .
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a GitHub issue `{{ issue.identifier }}`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Execution requirements:

1. If the issue has `status:ready`, retarget it to `status:in-progress` before coding.
2. Implement the requested change and run validation.
3. Open or update a PR that includes `closes #<issue-number>`.
4. After validation passes and the PR is ready, retarget the issue to `status:review`.
5. Add one concise issue comment with PR URL and validation evidence.
6. Keep scope aligned to the issue body; if blocked, report blocker details in the issue.

