# Codex Session Bridge

Owns Codex app-server session lifecycle concerns.

- Validate and normalize workspace cwd values.
- Start and stop local or remote app-server transports.
- Initialize JSON-RPC session state and Codex thread metadata.
- Handle idle transport messages for persistent sessions.
