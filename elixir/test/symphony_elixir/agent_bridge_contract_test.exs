defmodule SymphonyElixir.AgentBridgeContractTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.AgentBridge.ContractCase

  alias SymphonyElixir.AgentBridge.{Codex, TestBridge}

  define_basic_contract_tests(
    bridge: TestBridge,
    context_builder: fn ->
      %{
        workspace: "/tmp/mock-agent-bridge-workspace",
        issue: %Issue{
          id: "mock-issue",
          identifier: "MOCK-1",
          title: "Mock bridge contract",
          description: "Exercise the generic bridge contract",
          state: "In Progress",
          url: "https://example.org/issues/MOCK-1",
          labels: ["test"]
        },
        opts: []
      }
    end
  )

  define_basic_contract_tests(
    bridge: Codex,
    context_builder: fn ->
      test_root = tmp_dir!("agent-bridge-codex-contract")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "COD-1")
      codex_binary = Path.join(test_root, "fake-codex")

      on_exit(fn -> File.rm_rf(test_root) end)

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-contract"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-contract"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      %{
        workspace: workspace,
        issue: %Issue{
          id: "codex-contract-issue",
          identifier: "COD-1",
          title: "Codex bridge contract",
          description: "Exercise the generic bridge contract against Codex",
          state: "In Progress",
          url: "https://example.org/issues/COD-1",
          labels: ["backend"]
        },
        opts: []
      }
    end
  )
end
