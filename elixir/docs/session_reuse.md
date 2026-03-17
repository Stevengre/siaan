# Session Reuse

Symphony tracks two different session identifiers during issue execution:

- `issue_session_id`: the logical issue lifecycle across retries and review re-entry
- `physical_session_id`: the Codex thread / physical app-server session backing the current work

They are related, but they are not interchangeable.

## Logical Issue-Session Reuse

Logical reuse keeps one issue's execution history grouped together even when Symphony needs to
redispatch work. The logical issue session survives:

- continuation retries
- stall recovery
- `status:review -> status:in-progress` re-entry

This preserves issue-level observability such as total turns and aggregate token accounting.

## Physical Codex Session Reuse

Symphony records the physical Codex thread id for observability, but it does not currently reuse
that thread across redispatches.

Today each agent dispatch owns its own Codex app-server port and `AgentRunner` always stops that
session at the end of the run. Closing the app-server tears down the underlying Codex process, so
the prior thread is no longer resumable on the next dispatch.

On `status:review -> status:in-progress`, Symphony still reuses the logical `issue_session_id`, but
it starts a fresh physical Codex session and records why:

- `missing_previous_physical_session_id`: no earlier physical thread id was persisted
- `ephemeral_app_server_lifecycle`: a prior physical thread id existed, but the previous app-server
  process was already torn down and cannot be resumed today

## Observability

Runtime summaries, completed-run records, and dashboard rows should always keep these values
separate:

- logical: `issue_session_id`
- physical: `physical_session_id`
- reuse outcome: `physical_session_reuse_decision`
- fallback detail: `physical_session_fallback_reason`
