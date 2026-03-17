defmodule SymphonyElixir.DispatchLifecycle do
  @moduledoc false

  alias SymphonyElixir.{SessionStats, Tracker, TrackerIssue}

  @continuity_transitions ["retry_continuation", "stall_recovery", "resume_in_progress"]

  @spec transition_name(String.t(), String.t()) :: String.t() | nil
  def transition_name(from_state, to_state)
      when is_binary(from_state) and is_binary(to_state) do
    from_segment = state_transition_segment(from_state)
    to_segment = state_transition_segment(to_state)

    if from_segment != nil and to_segment != nil do
      "#{from_segment}_to_#{to_segment}"
    end
  end

  def transition_name(_from_state, _to_state), do: nil

  @spec dispatch_target_state(String.t() | nil) :: String.t() | nil
  def dispatch_target_state(issue_state) do
    Tracker.dispatch_target_state(issue_state)
  end

  @spec dispatch_transition_required?(String.t() | nil) :: boolean()
  def dispatch_transition_required?(issue_state) do
    is_binary(dispatch_target_state(issue_state))
  end

  @spec initial_dispatch_transition_name(String.t() | nil) :: String.t() | nil
  def initial_dispatch_transition_name(issue_state) do
    with target_state when is_binary(target_state) <- dispatch_target_state(issue_state) do
      transition_name(issue_state, target_state)
    end
  end

  @spec initial_dispatch_transition_name?(String.t() | nil) :: boolean()
  def initial_dispatch_transition_name?(transition_name) when is_binary(transition_name) do
    case Tracker.initial_dispatch_transition_name() do
      initial when is_binary(initial) -> transition_name == initial
      _ -> false
    end
  end

  def initial_dispatch_transition_name?(_transition_name), do: false

  @spec resolve_dispatch_transition(TrackerIssue.t() | nil, String.t() | nil) :: String.t()
  def resolve_dispatch_transition(%TrackerIssue{state: issue_state} = issue, explicit_transition)
      when is_binary(issue_state) do
    cond do
      dispatch_transition_required?(issue_state) ->
        initial_dispatch_transition_name(issue_state) || fallback_transition_name(issue_state)

      is_binary(explicit_transition) and String.trim(explicit_transition) != "" ->
        String.trim(explicit_transition)

      true ->
        SessionStats.consume_pending_transition(issue.id) || fallback_transition_name(issue_state)
    end
  end

  def resolve_dispatch_transition(_issue, explicit_transition) when is_binary(explicit_transition) do
    case String.trim(explicit_transition) do
      "" -> "resume_dispatch"
      trimmed -> trimmed
    end
  end

  def resolve_dispatch_transition(_issue, _explicit_transition), do: "resume_dispatch"

  @spec default_profile_name_for_transition(TrackerIssue.t(), String.t() | nil, map() | nil) ::
          String.t()
  def default_profile_name_for_transition(issue, transition_name, issue_session) do
    cond do
      is_binary(transition_name) and String.trim(transition_name) != "" and
          transition_name not in @continuity_transitions ->
        String.trim(transition_name)

      is_map(issue_session) and is_binary(issue_session["execution_profile"]) and
          issue_session["execution_profile"] != "" ->
        issue_session["execution_profile"]

      true ->
        fallback_profile_name(issue)
    end
  end

  @spec pick_profile_name(map() | nil, String.t() | nil, String.t()) :: String.t()
  def pick_profile_name(issue_session, transition_name, default_profile_name) do
    normalized_transition = normalize_optional_transition_name(transition_name)

    cond do
      normalized_transition in @continuity_transitions and is_map(issue_session) and
        is_binary(issue_session["execution_profile"]) and issue_session["execution_profile"] != "" ->
        issue_session["execution_profile"]

      is_binary(normalized_transition) and normalized_transition not in @continuity_transitions ->
        normalized_transition

      true ->
        default_profile_name
    end
  end

  @spec prepare_issue_for_dispatch(
          TrackerIssue.t(),
          (String.t(), String.t() -> term()),
          ([String.t()] -> {:ok, [TrackerIssue.t()]} | {:error, term()})
        ) :: {:ok, TrackerIssue.t()} | {:error, term()}
  def prepare_issue_for_dispatch(
        %TrackerIssue{state: issue_state} = issue,
        update_issue_state_fun,
        fetch_issue_states_fun
      )
      when is_binary(issue_state) and is_function(update_issue_state_fun, 2) and
             is_function(fetch_issue_states_fun, 1) do
    case dispatch_target_state(issue_state) do
      target_state when is_binary(target_state) ->
        case update_issue_state_fun.(issue.id, target_state) do
          :ok ->
            refresh_transitioned_issue(issue, target_state, fetch_issue_states_fun)

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, issue}
    end
  end

  def prepare_issue_for_dispatch(issue, _update_issue_state_fun, _fetch_issue_states_fun),
    do: {:ok, issue}

  defp fallback_profile_name(%TrackerIssue{state: issue_state}) when is_binary(issue_state) do
    initial_dispatch_transition_name(issue_state) || fallback_transition_name(issue_state)
  end

  defp fallback_profile_name(_issue), do: "resume_dispatch"

  defp refresh_transitioned_issue(%TrackerIssue{id: issue_id}, _target_state, fetch_issue_states_fun)
       when is_binary(issue_id) and is_function(fetch_issue_states_fun, 1) do
    case fetch_issue_states_fun.([issue_id]) do
      {:ok, [%TrackerIssue{} = refreshed_issue | _]} ->
        {:ok, refreshed_issue}

      {:ok, []} ->
        {:error, {:issue_state_refresh_failed, :issue_not_found}}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp refresh_transitioned_issue(issue, target_state, _fetch_issue_states_fun)
       when is_binary(target_state),
       do: {:ok, %{issue | state: target_state}}

  defp state_transition_segment(state_name) when is_binary(state_name) do
    state_name
    |> normalize_state()
    |> String.replace_prefix("status:", "")
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      segment -> segment
    end
  end

  defp fallback_transition_name(issue_state) when is_binary(issue_state) do
    case state_transition_segment(issue_state) do
      nil -> "resume_dispatch"
      segment -> "resume_#{segment}"
    end
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_optional_transition_name(transition_name) when is_binary(transition_name) do
    case String.trim(transition_name) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_transition_name(_transition_name), do: nil
end
