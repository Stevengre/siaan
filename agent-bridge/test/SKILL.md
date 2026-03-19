# Agent Bridge Test Framework

Provides generic bridge-contract helpers and a mock implementation for bridge-level tests.

- `lib/symphony_elixir/agent_bridge/contract_case.ex`: shared ExUnit macro for basic bridge contract coverage.
- `lib/symphony_elixir/agent_bridge/test_bridge.ex`: mock bridge implementation used to verify the interface contract independent of Codex.

Use this folder to exercise interface-level expectations against any concrete bridge module.
