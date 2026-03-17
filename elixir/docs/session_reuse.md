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

Symphony keeps a live Codex app-server session for an issue while that issue remains in the active
or watch lifecycle. When a later dispatch targets the same issue, Symphony reuses that live
physical session instead of starting a new thread.

This applies to:

- `status:review -> status:in-progress` re-entry when the prior runner/session is still alive
- continuation retries while the same issue session stays resident in the orchestrator
- multi-turn dispatches within the same long-lived runner

If the live runner/session is gone, Symphony deterministically starts a fresh physical session and
records the fallback reason. The persisted `physical_session_id` remains useful for observability,
but the reusable runtime object is the live runner/app-server session, not just the stored thread
id.

## Observability

Runtime summaries, completed-run records, and dashboard rows should always keep these values
separate:

- logical: `issue_session_id`
- physical: `physical_session_id`
- reuse outcome: `physical_session_reuse_decision`
- fallback detail: `physical_session_fallback_reason`
