defmodule SymphonyElixir.SessionStats do
  @moduledoc false

  alias SymphonyElixir.SessionTracker.{Metering, Persistence}

  defdelegate recent_history_limit(), to: Persistence
  defdelegate load_recent_history(limit \\ Persistence.recent_history_limit()), to: Persistence
  defdelegate append_history_record(record), to: Persistence
  defdelegate load_issue_session(issue_id), to: Persistence
  defdelegate load_issue_sessions(), to: Persistence
  defdelegate save_issue_session(record), to: Persistence
  defdelegate delete_issue_session(issue_id), to: Persistence
  defdelegate consume_pending_transition(issue_id), to: Persistence

  defdelegate consume_pending_transition_for_test(
                issue_id,
                load_issue_session_fun,
                save_issue_session_fun
              ),
              to: Persistence

  defdelegate mark_pending_transition(issue_id, issue_identifier, transition), to: Persistence
  defdelegate app_version(), to: Metering
  defdelegate configured_model(), to: Metering
  defdelegate configured_model(command), to: Metering
  defdelegate build_running_summary(running_entry), to: Metering
  defdelegate build_completed_record(running_entry, result), to: Metering
  defdelegate estimate_cost(model, input_tokens, output_tokens), to: Metering
  defdelegate workspace_git_metadata(workspace_path), to: Metering
end
