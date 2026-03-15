# Developing siaan

This guide is for contributing to siaan itself — not for using siaan on your own repo. For usage, see the [README](../README.md).

## Prerequisites

- [mise](https://mise.jdx.dev/getting-started.html) for toolchain management
- Elixir/Erlang (managed by mise)
- Docker & Docker Compose (for containerized runs)

## Local development (non-Docker)

```bash
cd elixir
mise trust && mise install
mise exec -- mix setup
mise exec -- mix build
```

## Running from source

```bash
# Loads .env automatically when present
./start-siaan.sh --bootstrap --port 4000

# Subsequent runs (skip bootstrap)
./start-siaan.sh --port 4000
```

## Running via Docker (this repo)

```bash
# Create .env at the repo root
cat > .env <<'EOF'
GITHUB_TOKEN=ghp_...
OPENAI_API_KEY=sk-...
GIT_AUTHOR_NAME=siaan-bot
GIT_AUTHOR_EMAIL=siaan-bot@users.noreply.github.com
EOF

docker compose up -d --build
docker compose logs -f siaan
```

The `docker-compose.yml` in this repo is pre-configured to point at `Stevengre/siaan` itself (self-hosting).

## Running tests

```bash
cd elixir
mise exec -- mix test
```

## mix siaan.install

Bootstrap or re-converge a target repo's labels, security guardrails, and allowlist:

```bash
cd elixir
mix siaan.install          # interactive
mix siaan.install --dry-run # preview only
mix siaan.install --yes     # accept defaults
```
