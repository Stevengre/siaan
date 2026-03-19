defmodule SymphonyElixir.PromptEngine.Continuation do
  @moduledoc false

  alias SymphonyElixir.PromptEngine.Renderer

  @spec build_turn_prompt(map(), keyword(), pos_integer(), non_neg_integer(), non_neg_integer(), map(), module()) ::
          String.t()
  def build_turn_prompt(issue, opts, turn_number, max_turns, issue_turn_count, app_session, renderer_module \\ Renderer) do
    do_build_turn_prompt(issue, opts, turn_number, max_turns, issue_turn_count, app_session, renderer_module)
  end

  defp do_build_turn_prompt(issue, opts, 1, _max_turns, 0, _app_session, renderer_module) do
    renderer_module.build_prompt(issue, opts)
  end

  defp do_build_turn_prompt(
         _issue,
         _opts,
         1,
         max_turns,
         issue_turn_count,
         %{
           physical_session_reuse_decision: "reused_physical_session"
         },
         _renderer_module
       ) do
    build_reused_physical_session_prompt(issue_turn_count, max_turns)
  end

  defp do_build_turn_prompt(issue, opts, 1, max_turns, issue_turn_count, _app_session, renderer_module) do
    """
    #{renderer_module.build_prompt(issue, opts)}

    Ongoing issue-session guidance:

    - This is a fresh physical Codex session for an existing issue session.
    - Previous issue-session turns completed: #{issue_turn_count}.
    - `agent.max_turns` still caps this physical agent run at #{max_turns} turns.
    - Reuse the current workspace and workpad state instead of redoing completed investigation.
    """
  end

  defp do_build_turn_prompt(_issue, _opts, turn_number, max_turns, issue_turn_count, _app_session, _renderer_module) do
    build_continuation_turn_prompt(turn_number, max_turns, issue_turn_count)
  end

  @spec build_continuation_turn_prompt(pos_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def build_continuation_turn_prompt(turn_number, max_turns, issue_turn_count) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - This corresponds to issue-session turn ##{issue_turn_count + turn_number}.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  @spec build_reused_physical_session_prompt(non_neg_integer(), non_neg_integer()) :: String.t()
  def build_reused_physical_session_prompt(issue_turn_count, max_turns) do
    """
    Continuation guidance:

    - The issue returned to active work on the same physical Codex session/thread.
    - This is continuation turn #1 of #{max_turns} for the current agent run.
    - This corresponds to issue-session turn ##{issue_turn_count + 1}.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior thread context are already present in this thread, so do not restate them before acting.
    """
  end
end
