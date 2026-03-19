defmodule SymphonyElixir.WorkflowEngineTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkflowEngine.Examples
  alias SymphonyElixir.WorkflowEngine.Interpreter
  alias SymphonyElixir.WorkflowEngine.MermaidParser
  alias SymphonyElixir.WorkflowEngine.StateMachine
  alias SymphonyElixir.WorkflowEngine.Validator

  test "parser converts Mermaid notes and transition annotations into machine structs" do
    assert {:ok, machine} = MermaidParser.parse(Examples.parser_demo_diagram(), id: "parser-demo")

    assert machine.id == "parser-demo"
    assert machine.initial_state == "ready"
    assert Map.fetch!(machine.states, "ready").activities == ["setup/workpad"]
    assert Map.fetch!(machine.states, "ready").metadata["owner"] == "agent"

    assert [
             %StateMachine.Transition{
               source: "ready",
               target: "in_progress",
               event: "dispatch",
               condition: "issue_is_ready",
               actions: ["mark_started"]
             },
             %StateMachine.Transition{
               source: "in_progress",
               target: "__end__",
               event: "finish",
               condition: "done"
             }
           ] = machine.transitions
  end

  test "parser rejects invalid diagrams and unterminated notes" do
    assert {:error, :invalid_mermaid_state_diagram} = MermaidParser.parse("graph TD\n  a --> b")

    assert {:error, {:unterminated_note, "ready"}} =
             MermaidParser.parse("""
             stateDiagram-v2
               [*] --> ready
               note right of ready
                 activity: setup
             """)
  end

  test "parser supports simple states, duplicate declarations, csv actions, and freeform note metadata" do
    assert {:ok, machine} =
             MermaidParser.parse("""
             stateDiagram
               [*] --> ready
               state ready
               state "Ready Label" as ready
               note left of ready
                 retries: 2
                 terminal: false
                 plain text note
                 second note line
               end note
               ready --> done: ship [actions: pack, send] [priority: 3]
               done --> [*]
             """)

    assert Map.fetch!(machine.states, "ready").label == "Ready Label"
    assert Map.fetch!(machine.states, "ready").metadata["retries"] == 2
    assert Map.fetch!(machine.states, "ready").metadata["terminal"] == false
    assert Map.fetch!(machine.states, "ready").metadata["note"] == "plain text note\nsecond note line"
    assert Enum.at(machine.transitions, 0).actions == ["pack", "send"]
    assert Enum.at(machine.transitions, 0).metadata["priority"] == 3
    assert Enum.at(machine.transitions, 1).event == nil
  end

  test "parser can return a machine without an explicit initial state" do
    assert {:ok, machine} =
             MermaidParser.parse("""
             stateDiagram-v2
               state idle
             """)

    assert machine.initial_state == nil
    assert Map.fetch!(machine.states, "idle").label == "idle"
  end

  test "parser does not duplicate activities when a state has multiple notes" do
    assert {:ok, machine} =
             MermaidParser.parse("""
             stateDiagram-v2
               [*] --> ready
               note right of ready
                 activity: setup
               end note
               note left of ready
                 activity: verify
               end note
             """)

    assert Map.fetch!(machine.states, "ready").activities == ["setup", "verify"]
  end

  test "parser supports annotation-only transition labels" do
    assert {:ok, machine} =
             MermaidParser.parse("""
             stateDiagram-v2
               [*] --> ready
               ready --> done: [condition: checks_pass]
             """)

    assert [%StateMachine.Transition{event: nil, condition: "checks_pass"}] = machine.transitions
  end

  test "parser rejects unsupported lines and invalid initial end transitions" do
    assert {:error, {:unsupported_mermaid_line, "ready : nope"}} =
             MermaidParser.parse("""
             stateDiagram-v2
               ready : nope
             """)

    assert {:error, {:invalid_initial_transition, "[*] --> [*]"}} =
             MermaidParser.parse("""
             stateDiagram-v2
               [*] --> [*]
             """)
  end

  test "interpreter evaluates transitions in order and runs activities/actions" do
    assert {:ok, machine} = MermaidParser.parse(Examples.github_issue_workflow_diagram())

    activity_runner = fn
      "issue/bootstrap-workpad", context -> {:ok, Map.update(context, :activities, ["bootstrap"], &(&1 ++ ["bootstrap"]))}
      "git/pull-origin-main", context -> {:ok, Map.update(context, :activities, ["pull"], &(&1 ++ ["pull"]))}
      "issue/reconcile-workpad", context -> {:ok, Map.update(context, :activities, ["reconcile"], &(&1 ++ ["reconcile"]))}
      "implementation/execute-plan", context -> {:ok, Map.update(context, :activities, ["execute"], &(&1 ++ ["execute"]))}
      "review/check-pr-feedback", context -> {:ok, Map.update(context, :activities, ["feedback"], &(&1 ++ ["feedback"]))}
      "review/monitor-ci", context -> {:ok, Map.update(context, :activities, ["ci"], &(&1 ++ ["ci"]))}
      "issue/archive", context -> {:ok, Map.update(context, :activities, ["archive"], &(&1 ++ ["archive"]))}
    end

    action_runner = fn
      "mark_in_progress", context -> {:ok, Map.update(context, :actions, ["in_progress"], &(&1 ++ ["in_progress"]))}
      "open_or_update_pr", context -> {:ok, Map.update(context, :actions, ["push"], &(&1 ++ ["push"]))}
      "mark_review", context -> {:ok, Map.update(context, :actions, ["review"], &(&1 ++ ["review"]))}
      "finalize_issue", context -> {:ok, Map.update(context, :actions, ["finalize"], &(&1 ++ ["finalize"]))}
      "requeue_execution", context -> {:ok, Map.update(context, :actions, ["requeue"], &(&1 ++ ["requeue"]))}
    end

    condition_evaluator = fn
      "issue_is_ready", _context -> true
      "acceptance_complete", _context -> true
      "review_blocked", _context -> false
      "review_approved", _context -> true
    end

    assert {:ok, runtime} =
             Interpreter.run(machine,
               context: %{},
               activity_runner: activity_runner,
               action_runner: action_runner,
               condition_evaluator: condition_evaluator
             )

    assert runtime.halted
    assert runtime.current_state == StateMachine.end_state_id()
    assert runtime.context.activities == ["bootstrap", "pull", "reconcile", "execute", "feedback", "ci", "archive"]
    assert runtime.context.actions == ["in_progress", "push", "review", "finalize"]
    assert Enum.at(runtime.history, 0) == %{type: :enter, state: "ready", activities: ["issue/bootstrap-workpad", "git/pull-origin-main"]}
    assert List.last(runtime.history) == %{type: :halt, state: "__end__"}
  end

  test "interpreter reports stalled runs and execution contract failures" do
    assert {:ok, machine} = MermaidParser.parse(Examples.parser_demo_diagram())
    assert {:ok, runtime} = Interpreter.start(machine, context: %{})

    assert {:stalled, ^runtime, [{"in_progress", :condition_failed, "issue_is_ready"}]} =
             Interpreter.advance(runtime, condition_evaluator: fn _, _ -> false end)

    assert {:error, {:condition_evaluation_failed, "issue_is_ready", :boom}} =
             Interpreter.advance(runtime, condition_evaluator: fn _, _ -> {:error, :boom} end)

    assert {:error, {:invalid_effect_result, "setup/workpad", :bad_return}} =
             Interpreter.start(machine, activity_runner: fn _, _ -> :bad_return end)

    assert {:error, :missing_initial_state} = Interpreter.start(%StateMachine{})
    assert {:stalled, halted_runtime, [:halted]} = Interpreter.advance(%Interpreter.Runtime{halted: true})
    assert halted_runtime.halted
  end

  test "interpreter covers default runners, :ok actions, stalled runs, and invalid condition results" do
    assert {:ok, machine} =
             MermaidParser.parse("""
             stateDiagram-v2
               [*] --> draft
               state draft
               note right of draft
                 activity: noop
               end note
               draft --> review: submit [condition: ready]
               draft --> done: fallback [condition: fallback] [action: noop_action]
               review --> [*]
               done --> [*]
             """)

    assert {:ok, started_runtime} = Interpreter.start(machine)
    assert started_runtime.context == %{}

    assert {:error, {:condition_evaluation_failed, "ready", :missing_condition_evaluator}} =
             Interpreter.advance(started_runtime)

    assert {:error, {:invalid_condition_result, "ready", :maybe}} =
             Interpreter.advance(started_runtime, condition_evaluator: fn _, _ -> :maybe end)

    assert {:stalled, _runtime, [{"review", :condition_failed, "ready"}, {"done", :condition_failed, "fallback"}]} =
             Interpreter.advance(started_runtime,
               condition_evaluator: fn
                 "ready", _context -> {:ok, false}
                 "fallback", _context -> {:ok, false}
               end
             )

    assert {:stalled, _stalled_runtime, [{"review", :condition_failed, "ready"}, {"done", :condition_failed, "fallback"}]} =
             Interpreter.advance(started_runtime,
               condition_evaluator: fn
                 "ready", _context -> false
                 "fallback", _context -> false
               end
             )

    assert {:error, {:condition_evaluation_failed, "ready", :missing_condition_evaluator}} = Interpreter.run(machine)

    assert {:ok, run_runtime} =
             Interpreter.run(machine,
               action_runner: fn _action, _context -> :ok end,
               condition_evaluator: fn
                 "ready", _context -> false
                 "fallback", _context -> true
               end
             )

    assert run_runtime.halted

    assert {:ok, stalled_run_runtime} =
             Interpreter.run(machine,
               condition_evaluator: fn
                 "ready", _context -> false
                 "fallback", _context -> false
               end
             )

    refute stalled_run_runtime.halted

    assert {:error, {:effect_failed, "go", :denied}} =
             Interpreter.advance(
               %Interpreter.Runtime{
                 machine: %StateMachine{
                   initial_state: "draft",
                   states: %{"draft" => %StateMachine.State{id: "draft", label: "draft"}},
                   transitions: [%StateMachine.Transition{source: "draft", target: "__end__", actions: ["go"]}]
                 },
                 current_state: "draft",
                 context: %{}
               },
               action_runner: fn _, _ -> {:error, :denied} end
             )
  end

  test "validator reports unreachable states, deadlocks, missing conditions, and missing initial state" do
    assert {:ok, machine} = MermaidParser.parse(Examples.invalid_diagram())
    analysis = Validator.analyze(machine)

    assert analysis.unreachable_states == ["lonely"]
    assert analysis.deadlocks == ["blocked", "review"]
    assert analysis.missing_conditions == [%{source: "ready", target: "review"}]
    assert {:error, findings} = Validator.validate(machine)
    assert {:unreachable_state, "lonely"} in findings
    assert {:deadlock_state, "review"} in findings
    assert {:missing_condition, %{source: "ready", target: "review"}} in findings

    blank_initial = %StateMachine{states: %{"ready" => %StateMachine.State{id: "ready", label: "ready"}}}
    assert {:error, blank_findings} = Validator.validate(blank_initial)
    assert {:missing_initial_state, nil} in blank_findings
  end

  test "validator reports an initial state that is not declared" do
    machine = %StateMachine{initial_state: "ready", states: %{}}

    analysis = Validator.analyze(machine)
    assert {:unknown_initial_state, "ready"} in analysis.findings
    assert {:error, findings} = Validator.validate(machine)
    assert {:unknown_initial_state, "ready"} in findings
  end

  test "validator reports transitions that reference unknown states" do
    machine = %StateMachine{
      initial_state: "ready",
      states: %{"ready" => %StateMachine.State{id: "ready", label: "ready"}},
      transitions: [
        %StateMachine.Transition{source: "ghost", target: "ready"},
        %StateMachine.Transition{source: "ready", target: "missing"}
      ]
    }

    analysis = Validator.analyze(machine)
    assert {:unknown_transition_source, "ghost"} in analysis.findings
    assert {:unknown_transition_target, "missing"} in analysis.findings
  end

  test "github issue workflow example parses, validates, and ships the condition manifest" do
    assert manifest = Examples.github_issue_conditions_manifest()
    assert manifest =~ "issue_is_ready"
    assert manifest =~ "open_or_update_pr"

    assert {:ok, machine} = MermaidParser.parse(Examples.github_issue_workflow_diagram(), id: "github-issue")
    assert :ok = Validator.validate(machine)
    assert Map.fetch!(machine.states, "closed").metadata["terminal"] == true
  end
end
