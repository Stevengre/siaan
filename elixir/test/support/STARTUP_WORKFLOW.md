---
tracker:
  kind: memory
  endpoint: null
  api_key: null
  project_slug: null
  repo_owner: null
  repo_name: null
  ready_label: "status:ready"
  assignee: null
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
polling:
  interval_ms: 30000
workspace:
  root: "/tmp/symphony_startup_workspaces"
agent:
  max_concurrent_agents: 1
  max_turns: 20
  max_retry_backoff_ms: 300000
  max_concurrent_agents_by_state: {}
codex:
  command: "codex app-server"
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: "workspace-write"
  turn_sandbox_policy: null
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
allowlist: []
hooks:
  timeout_ms: 60000
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  render_interval_ms: 16
---
You are an agent for this repository.
