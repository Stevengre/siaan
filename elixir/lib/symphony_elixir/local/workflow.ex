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

  defp normalize_state_config(_state_name, state_config) when is_map(state_config) do
    activities =
      state_config
      |> Map.get("activities", [])
      |> Enum.map(&normalize_activity/1)

    transitions =
      state_config
      |> Map.get("transitions", [])
      |> Enum.map(&normalize_transition/1)

    {:ok, %{activities: activities, transitions: transitions}}
  end

  defp normalize_state_config(state_name, state_config) do
    {:error, {:invalid_state_config, to_string(state_name), state_config}}
  end

  defp normalize_activity(%{"skill" => name}) do
    %Activity{type: :skill, name: to_string(name)}
  end

  defp normalize_activity(%{"check" => name} = activity) do
    %Activity{type: :check, name: to_string(name), interval: Map.get(activity, "interval")}
  end

  defp normalize_activity(activity) do
    raise ArgumentError, "unsupported workflow activity: #{inspect(activity)}"
  end

  defp normalize_transition(%{"to" => target} = transition) do
    conditions =
      transition
      |> Map.get("when", [])
      |> Enum.map(&to_string/1)

    %Transition{to: to_string(target), when: conditions}
  end

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
