defmodule SymphonyElixir.Local.Workflow do
  @moduledoc """
  Loads and evaluates the local workflow DSL from `workflow.yaml`.
  """

  require Logger

  defmodule Activity do
    @moduledoc false
    defstruct [:type, :name, :interval]

    @type t :: %__MODULE__{
            type: :skill | :check | nil,
            name: String.t() | nil,
            interval: String.t() | nil
          }
  end

  defmodule Transition do
    @moduledoc false
    defstruct [:to, when: []]

    @type t :: %__MODULE__{
            to: String.t() | nil,
            when: [String.t()]
          }
  end

  @type t :: %{
          optional(String.t()) => %{activities: [Activity.t()], transitions: [Transition.t()]}
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(contents),
         {:ok, workflow} <- normalize(decoded) do
      if is_map(decoded) do
        {:ok, workflow}
      else
        {:error, :workflow_not_a_map}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @spec first_matching_transition(t(), String.t(), Path.t(), keyword()) ::
          {:ok, Transition.t() | nil} | {:error, term()}
  def first_matching_transition(workflow, current_state, issue_path, opts \\ [])
      when is_map(workflow) and is_binary(current_state) and is_binary(issue_path) do
    transitions =
      workflow
      |> Map.get(current_state, %{transitions: []})
      |> Map.get(:transitions, [])

    Enum.reduce_while(transitions, {:ok, nil}, fn %Transition{} = transition, _acc ->
      case transition_matches?(transition, issue_path, opts) do
        {:ok, true} -> {:halt, {:ok, transition}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec first_matching_transition_to(t(), String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, Transition.t() | nil} | {:error, term()}
  def first_matching_transition_to(workflow, current_state, target_state, issue_path, opts \\ [])
      when is_binary(current_state) and is_binary(target_state) do
    transitions =
      workflow
      |> Map.get(current_state, %{transitions: []})
      |> Map.get(:transitions, [])
      |> Enum.filter(&(&1.to == target_state))

    Enum.reduce_while(transitions, {:ok, nil}, fn %Transition{} = transition, _acc ->
      case transition_matches?(transition, issue_path, opts) do
        {:ok, true} -> {:halt, {:ok, transition}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize(decoded) when is_map(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn {state_name, state_config}, {:ok, acc} ->
      case normalize_state_config(state_name, state_config) do
        {:ok, normalized_state_config} ->
          {:cont, {:ok, Map.put(acc, to_string(state_name), normalized_state_config)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp normalize(_decoded), do: {:error, :workflow_not_a_map}

  defp normalize_state_config(state_name, state_config) when is_map(state_config) do
    with {:ok, activities} <-
           normalize_list_field(state_name, state_config, "activities", &normalize_activity/1),
         {:ok, transitions} <-
           normalize_list_field(state_name, state_config, "transitions", &normalize_transition/1) do
      {:ok, %{activities: activities, transitions: transitions}}
    end
  end

  defp normalize_state_config(state_name, state_config) do
    {:error, {:invalid_state_config, to_string(state_name), state_config}}
  end

  defp normalize_list_field(state_name, state_config, key, mapper) when is_function(mapper, 1) do
    case Map.get(state_config, key, []) do
      values when is_list(values) ->
        normalize_list_values(values, mapper)

      value ->
        {:error, {:invalid_state_list, to_string(state_name), key, value}}
    end
  end

  defp normalize_list_values(values, mapper) when is_list(values) and is_function(mapper, 1) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_normalized_values()
  end

  defp reverse_normalized_values({:ok, normalized_values}), do: {:ok, Enum.reverse(normalized_values)}
  defp reverse_normalized_values({:error, _reason} = error), do: error

  defp normalize_activity(%{"skill" => name}) do
    {:ok, %Activity{type: :skill, name: to_string(name)}}
  end

  defp normalize_activity(%{"check" => name} = activity) do
    {:ok, %Activity{type: :check, name: to_string(name), interval: Map.get(activity, "interval")}}
  end

  defp normalize_activity(activity), do: {:error, {:invalid_activity, activity}}

  defp normalize_transition(%{"to" => target} = transition) do
    case Map.get(transition, "when", []) do
      conditions when is_list(conditions) ->
        {:ok, %Transition{to: to_string(target), when: Enum.map(conditions, &to_string/1)}}

      value ->
        {:error, {:invalid_transition_conditions, to_string(target), value}}
    end
  end

  defp normalize_transition(transition), do: {:error, {:invalid_transition, transition}}

  defp transition_matches?(%Transition{to: target, when: conditions}, issue_path, opts) do
    Logger.info("Evaluating workflow transition target=#{target} issue_path=#{issue_path}")

    Enum.reduce_while(conditions, {:ok, true}, fn condition, _acc ->
      case run_condition(condition, issue_path, opts) do
        {:ok, 0} ->
          Logger.info("Workflow condition passed command=#{inspect(condition)} issue_path=#{issue_path}")

          {:cont, {:ok, true}}

        {:ok, status} ->
          Logger.info("Workflow condition failed command=#{inspect(condition)} issue_path=#{issue_path} exit_status=#{status}")

          {:halt, {:ok, false}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp run_condition(command, issue_path, opts) do
    runner = Keyword.get(opts, :runner, &default_runner/2)
    runner.(command, issue_path)
  end

  defp default_runner(command, issue_path) when is_binary(command) and is_binary(issue_path) do
    case System.cmd("/bin/sh", ["-lc", "#{command} \"$1\"", "sh", issue_path], stderr_to_stdout: true) do
      {_output, status} -> {:ok, status}
    end
  rescue
    error -> {:error, error}
  end
end
