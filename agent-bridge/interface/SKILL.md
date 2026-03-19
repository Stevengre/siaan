# Agent Bridge Interface

Defines the agent bridge contract shared by orchestrator-facing bridge implementations.

- `lib/symphony_elixir/agent_bridge.ex`: behaviour callbacks for session lifecycle, turn execution, and idle transport handling.
- `lib/symphony_elixir/agent_bridge/session.ex`: common session struct shared across bridge implementations.
- `lib/symphony_elixir/agent_bridge/message.ex`: shared streamed message shape helpers.

Constraints:

- Keep this folder free of Codex, JSON-RPC, and port-specific concepts.
- Treat the session `native` and `state` fields as bridge-private storage.
