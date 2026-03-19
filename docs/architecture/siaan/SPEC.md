# Architecture SPEC

_Generated: 2026-03-19T00:47:59.774670+00:00_

## Overview

This repository runs an issue-driven automation loop: tracker adapters surface work, the orchestrator decides when to dispatch, workspaces isolate execution, the workflow engine builds prompt/runtime context, the agent bridge talks to Codex, and state-sync stores keep the system resilient across retries and reloads.

## Runtime Signals

- Entrypoints: start-siaan.sh, docker-compose.yml, Dockerfile, elixir/lib/symphony_elixir/cli.ex, elixir/lib/symphony_elixir/http_server.ex
- Primary languages: elixir (57)
- Source modules scanned: 57

## Architecture Components

### state-sync

Caches runtime state, issue sessions, and last-known-good config for resilient orchestration.

- Paths: elixir/lib/symphony_elixir/runtime_config_store.ex, elixir/lib/symphony_elixir/runtime_source.ex, elixir/lib/symphony_elixir/runtime_source_store.ex, elixir/lib/symphony_elixir/session_stats.ex, elixir/lib/symphony_elixir/tracker/memory.ex
- Member count: 5
- Primary languages: elixir
- Depends on: dispatch, scope:elixir, workflow-engine
- Used by: workflow-engine

### workflow-engine

Loads workflow/runtime configuration and materializes prompt contracts for each issue.

- Paths: elixir/lib/symphony_elixir/config/schema.ex, elixir/lib/symphony_elixir/local/workflow.ex, elixir/lib/symphony_elixir/prompt_builder.ex, elixir/lib/symphony_elixir/runtime_config.ex, elixir/lib/symphony_elixir/runtime_config_file.ex, elixir/lib/symphony_elixir/runtime_file.ex
- Member count: 8
- Primary languages: elixir
- Depends on: state-sync, workspace
- Used by: orchestrator, state-sync

### agent-bridge

Bridges repository workspaces to Codex app-server sessions and dynamic tools.

- Paths: elixir/lib/symphony_elixir/agent_runner.ex, elixir/lib/symphony_elixir/codex/app_server.ex, elixir/lib/symphony_elixir/codex/dynamic_tool.ex
- Member count: 3
- Primary languages: elixir
- Depends on: scope:elixir
- Used by: none observed

### workspace

Creates, validates, and cleans isolated issue workspaces across local and SSH workers.

- Paths: elixir/lib/mix/tasks/workspace.before_remove.ex, elixir/lib/symphony_elixir/path_safety.ex, elixir/lib/symphony_elixir/ssh.ex, elixir/lib/symphony_elixir/workspace.ex
- Member count: 4
- Primary languages: elixir
- Depends on: none observed
- Used by: workflow-engine

### dispatch

Translates tracker state into execution transitions and routes work between adapters.

- Paths: elixir/lib/symphony_elixir/dispatch_lifecycle.ex, elixir/lib/symphony_elixir/github/adapter.ex, elixir/lib/symphony_elixir/github/issue.ex, elixir/lib/symphony_elixir/linear/adapter.ex, elixir/lib/symphony_elixir/linear/issue.ex, elixir/lib/symphony_elixir/local/adapter.ex
- Member count: 8
- Primary languages: elixir
- Depends on: scope:elixir
- Used by: orchestrator, scope:elixir, state-sync

### orchestrator

Coordinates polling, dispatch, retries, and session lifecycle decisions.

- Paths: elixir/lib/symphony_elixir.ex, elixir/lib/symphony_elixir/http_server.ex, elixir/lib/symphony_elixir/local/issue.ex, elixir/lib/symphony_elixir/orchestrator.ex, elixir/lib/symphony_elixir/status_dashboard.ex, elixir/lib/symphony_elixir_web/components/layouts.ex
- Member count: 12
- Primary languages: elixir
- Depends on: dispatch, workflow-engine
- Used by: none observed

## Interactions

1. `dispatch` fetches candidate issues and computes the transition/profile to run.
2. `orchestrator` coordinates retries, capacity, and dispatch scheduling.
3. `workspace` provisions an isolated execution root for the chosen issue.
4. `workflow-engine` loads runtime config and prompt templates for the run.
5. `agent-bridge` starts the Codex app-server session and executes turns against the workspace.
6. `state-sync` persists reusable session/config state so the loop survives reloads and re-entry.

## Diagrams

- `dispatch-sequence.mmd`
- `l1-system-context.mmd`
- `l2-container-view.mmd`
- `l3-component-view.mmd`
- `l4-code-map.mmd`

## Drift Candidates

- `docs/developing.md:3` references missing `../README.md`
- `elixir/README.md:4` references missing `../SPEC.md`

## Module Appendix

- `elixir/lib/mix/tasks/pr_body.check.ex`: Validates a PR description markdown file against the structure and expectations implied by the repository pull request template.
- `elixir/lib/mix/tasks/siaan.install.ex`: Install and maintain siaan for the current repository.
- `elixir/lib/mix/tasks/specs.check.ex`: Enforces adjacent `@spec` declarations for public APIs in `lib/`.
- `elixir/lib/mix/tasks/workspace.before_remove.ex`: Closes open pull requests for the current Git branch.
- `elixir/lib/symphony_elixir.ex`: Entry point for the Symphony orchestrator.
- `elixir/lib/symphony_elixir/agent_runner.ex`: Executes a single tracker issue in its workspace with Codex.
- `elixir/lib/symphony_elixir/cli.ex`: Escript entrypoint for running Symphony with an explicit runtime config path.
- `elixir/lib/symphony_elixir/codex/app_server.ex`: Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`: Executes client-side tool calls requested by Codex app-server turns.
- `elixir/lib/symphony_elixir/config.ex`: Runtime configuration loaded from the configured runtime source.
- `elixir/lib/symphony_elixir/config/schema.ex`: Source module from `elixir/lib/symphony_elixir/config/schema.ex`.
- `elixir/lib/symphony_elixir/dispatch_lifecycle.ex`: Source module from `elixir/lib/symphony_elixir/dispatch_lifecycle.ex`.
- `elixir/lib/symphony_elixir/github/adapter.ex`: GitHub-backed tracker adapter.
- `elixir/lib/symphony_elixir/github/client.ex`: Thin GitHub REST/GraphQL client for issue polling and repository installation tasks.
- `elixir/lib/symphony_elixir/github/issue.ex`: Normalized GitHub issue representation used by the GitHub tracker integration.
- `elixir/lib/symphony_elixir/http_server.ex`: Compatibility facade that starts the Phoenix observability endpoint when enabled.
- `elixir/lib/symphony_elixir/install/repository.ex`: Source module from `elixir/lib/symphony_elixir/install/repository.ex`.
- `elixir/lib/symphony_elixir/install/runner.ex`: Source module from `elixir/lib/symphony_elixir/install/runner.ex`.
- `elixir/lib/symphony_elixir/install/security_file.ex`: Source module from `elixir/lib/symphony_elixir/install/security_file.ex`.
- `elixir/lib/symphony_elixir/linear/adapter.ex`: Linear-backed tracker adapter.
