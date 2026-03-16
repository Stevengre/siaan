#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GH_TOKEN:-}" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -n "${GH_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="$GH_TOKEN"
fi

export CODEX_HOME="${CODEX_HOME:-/root/code/workspaces/siaan/.codex-home}"
mkdir -p "$CODEX_HOME"

# Seed a writable Codex home from the read-only host mount on first run.
if [[ -d /root/.codex ]] && [[ "$CODEX_HOME" != "/root/.codex" ]]; then
  cp -a -n /root/.codex/. "$CODEX_HOME"/ 2>/dev/null || true
fi

git config --global user.name "${GIT_AUTHOR_NAME:-Codex}"
git config --global user.email \
  "${GIT_AUTHOR_EMAIL:-codex@users.noreply.github.com}"

if [[ -n "${GH_TOKEN:-}" ]] || [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  # Materialize a writable gh login so both shell commands and agent fallbacks
  # can update GitHub state without depending on transient env-only auth.
  if [[ -n "$auth_token" ]]; then
    printf '%s' "$auth_token" | gh auth login --hostname github.com --with-token >/dev/null 2>&1 || true
  fi

  gh auth setup-git >/dev/null 2>&1 || true
fi

exec ./bin/siaan "$@"
