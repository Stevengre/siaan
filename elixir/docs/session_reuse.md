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

Physical reuse attempts to continue on the same Codex thread when an issue returns from
`status:review` to `status:in-progress`.

When Symphony has a persisted `physical_session_id`, it starts a fresh app-server connection and
tries the next `turn/start` against that existing thread id.

- If Codex accepts the thread id, Symphony keeps the same `physical_session_id` and sends only
  continuation guidance instead of replaying the full bootstrap prompt.
- If Codex rejects the thread id, Symphony deterministically falls back to `thread/start`,
  records `physical_session_reuse_decision=started_new_physical_session`, and stores the exact
  fallback reason for observability.

## Observability

Runtime summaries, completed-run records, and dashboard rows should always keep these values
separate:

- logical: `issue_session_id`
- physical: `physical_session_id`
- reuse outcome: `physical_session_reuse_decision`
- fallback detail: `physical_session_fallback_reason`
