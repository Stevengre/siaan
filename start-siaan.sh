#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-siaan.sh [--bootstrap] [--port <port>] [--workflow <path>]

Options:
  --bootstrap        Run mise/mix setup steps before starting.
  --port <port>      Enable dashboard on the given port.
  --workflow <path>  Workflow file path (default: elixir/WORKFLOW.md).
  -h, --help         Show this help.

Environment:
  GITHUB_TOKEN       Required for GitHub tracker mode.
EOF
}

resolve_absolute_path() {
  local path="$1"
  local path_dir
  local path_file

  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi

  path_dir="$(cd "$(dirname "$path")" && pwd)"
  path_file="$(basename "$path")"

  printf '%s/%s\n' "$path_dir" "$path_file"
}

extract_tracker_kind() {
  local workflow_file="$1"

  awk '
    /^[[:space:]]*#/ { next }
    /^tracker:[[:space:]]*$/ { in_tracker = 1; next }
    in_tracker && /^[^[:space:]]/ { in_tracker = 0 }
    in_tracker && /^[[:space:]]+kind:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+kind:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*/, "", line)
      print line
      exit
    }
  ' "$workflow_file"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_dir="$script_dir/elixir"

bootstrap="false"
port=""
workflow="$elixir_dir/WORKFLOW.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)
      bootstrap="true"
      shift
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        echo "error: --port requires a value" >&2
        usage
        exit 1
      fi
      port="$2"
      shift 2
      ;;
    --workflow)
      if [[ $# -lt 2 ]]; then
        echo "error: --workflow requires a value" >&2
        usage
        exit 1
      fi
      workflow="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v mise >/dev/null 2>&1; then
  echo "error: 'mise' is required. Install from https://mise.jdx.dev/getting-started.html" >&2
  exit 1
fi

if [[ ! -f "$workflow" ]]; then
  echo "error: workflow file not found: $workflow" >&2
  exit 1
fi

workflow="$(resolve_absolute_path "$workflow")"

tracker_kind="$(
  extract_tracker_kind "$workflow" \
    | tr -d '"' \
    | tr -d "'" \
    | xargs
)"
tracker_kind="$(printf '%s' "$tracker_kind" | tr '[:upper:]' '[:lower:]')"

if [[ "$tracker_kind" == "github" ]] && [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "error: GITHUB_TOKEN is not set." >&2
  echo "run: export GITHUB_TOKEN=..." >&2
  exit 1
fi

cd "$elixir_dir"

if [[ "$bootstrap" == "true" ]]; then
  mise trust
  mise install
  mise exec -- mix setup
  mise exec -- mix build
fi

cmd=(
  mise exec -- ./bin/siaan
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
)

if [[ -n "$port" ]]; then
  cmd+=(--port "$port")
fi

cmd+=("$workflow")

echo "Starting siaan with workflow: $workflow"
exec "${cmd[@]}"
