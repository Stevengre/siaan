---
name: siaan-setup
description: Set up siaan to manage a GitHub repository. Creates the config directory, .env, docker-compose.yml, and WORKFLOW.md, then bootstraps the target repo and starts the loop.
status: not-tested
---

# siaan Setup Skill

## Overview

This skill guides the agent to set up siaan on a user's GitHub repository. The end result is a running siaan instance that polls issues and dispatches agents against the target repo.

## Prerequisites

Ask the user for:

1. **`GITHUB_TOKEN`** — a GitHub PAT with `repo` scope for the target repository
2. **Target repo** — the `owner/repo` to manage (e.g. `acme/my-app`)
3. **Config directory** — where to create the siaan config (default: `~/siaan-config/<repo-name>/`)

Verify Docker is available:
```bash
docker --version && docker compose version
```

## Steps

### 1. Create the config directory

```bash
mkdir -p <config-dir>
cd <config-dir>
```

### 2. Write `.env`

Create `<config-dir>/.env` with the required secret:

```bash
GITHUB_TOKEN=<user-provided-token>
```

### 3. Write `docker-compose.yml`

Create `<config-dir>/docker-compose.yml`:

```yaml
services:
  siaan:
    image: ghcr.io/stevengre/siaan:latest
    volumes:
      - ./WORKFLOW.md:/app/WORKFLOW.md:ro
      - ~/code/workspaces:/root/code/workspaces
    env_file: .env
    command: ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "/app/WORKFLOW.md"]
    restart: unless-stopped
```

### 4. Write `WORKFLOW.md`

Copy the template from the siaan repo (`elixir/WORKFLOW.md`) and substitute:

- `repo_owner` → the user's org/owner
- `repo_name` → the user's repo name
- `allowlist` → the user's GitHub username (and bot account if they have one)
- `workspace.root` → `/root/code/workspaces/<repo-name>`

### 5. Bootstrap the target repo

```bash
cd <config-dir>
docker compose run --rm siaan mix siaan.install
```

This installs the label taxonomy (`status:triage`, `status:ready`, etc.), security guardrails, and branch protection on the target repo.

Confirm with the user that the output looks correct.

### 6. Start siaan

```bash
docker compose up -d
```

Verify it's running:
```bash
docker compose logs -f siaan
```

Tell the user: "File an issue on your repo, label it `status:ready`, and siaan will pick it up."

## Optional configuration

Only offer these if the user asks:

| `.env` variable | Purpose | Default |
|---|---|---|
| `OPENAI_API_KEY` | Codex agent credentials | inherited from environment |
| `GIT_AUTHOR_NAME` | git identity for commits | `Codex` |
| `GIT_AUTHOR_EMAIL` | git email for commits | `codex@users.noreply.github.com` |

| `WORKFLOW.md` field | Purpose | Default |
|---|---|---|
| `polling.interval_ms` | poll frequency | `30000` (30s) |
| `agent.max_concurrent_agents` | parallel agent limit | `5` |
| `agent.max_turns` | max turns per agent | `7` |

## Do Not

- Do not write secrets to any file other than `.env`
- Do not modify the user's target repo directly — `mix siaan.install` handles that
- Do not start siaan before the user confirms the bootstrap output
