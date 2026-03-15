#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GH_TOKEN:-}" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -n "${GH_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="$GH_TOKEN"
fi

git config --global user.name "${GIT_AUTHOR_NAME:-Codex}"
git config --global user.email \
  "${GIT_AUTHOR_EMAIL:-codex@users.noreply.github.com}"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  gh auth login --with-token <<<"$GITHUB_TOKEN" >/dev/null
  gh auth setup-git >/dev/null
fi

exec ./bin/siaan "$@"
