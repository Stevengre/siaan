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
  ./.env             Loaded automatically when present.
  GITHUB_TOKEN       Required for GitHub tracker mode.
  GH_TOKEN           Accepted as an alias for GITHUB_TOKEN.

This script starts siaan directly on the host. For containerized runtime usage,
prefer: docker compose up -d --build siaan
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_dir="$script_dir/elixir"
env_file="$script_dir/.env"

resolve_absolute_path() {
  local path="$1"
  local dir
  local base
  local absolute_dir

  dir="$(dirname "$path")"
  base="$(basename "$path")"

  if absolute_dir="$(cd "$dir" 2>/dev/null && /bin/pwd -P)"; then
    printf '%s/%s\n' "$absolute_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

extract_state_type() {
  local workflow_path="$1"

  awk '
    function normalize_type_value(value) {
      sub(/^[[:space:]]*(type|kind):[[:space:]]*/, "", value)
      sub(/[[:space:]]*(,|}|#.*)?$/, "", value)
      gsub(/^["'"'"']/, "", value)
      gsub(/["'"'"']$/, "", value)
      return tolower(value)
    }

    function normalize_scalar_value(value) {
      sub(/[[:space:]]*(,|}|#.*)?$/, "", value)
      gsub(/^["'"'"']/, "", value)
      gsub(/["'"'"']$/, "", value)
      return tolower(value)
    }

    function section_name(line, section) {
      section = line
      sub(/^[[:space:]]*/, "", section)
      sub(/:.*/, "", section)
      return section
    }

    function capture_type(section, value) {
      value = normalize_scalar_value(value)

      if (section == "state" && state_type == "") {
        state_type = value
      }

      if (section == "tracker" && tracker_type == "") {
        tracker_type = value
      }
    }

    function capture_inline_state_type(section, line, candidate) {
      candidate = line

      if (!match(candidate, /(type|kind):[[:space:]]*["'"'"']?[^,}#[:space:]]+["'"'"']?/)) {
        return 0
      }

      candidate = substr(candidate, RSTART, RLENGTH)
      capture_type(section, normalize_type_value(candidate))
      return 1
    }

    BEGIN {
      current_section = ""
      section_indent = -1
      state_type = ""
      tracker_type = ""
    }

    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) {
        next
      }

      match($0, /[^[:space:]]/)
      indent = RSTART ? RSTART - 1 : 0
    }

    /^[[:space:]]*(state|tracker):[[:space:]]*{/ {
      capture_inline_state_type(section_name($0), $0)
      current_section = ""
      section_indent = -1

      next
    }

    /^[[:space:]]*(state|tracker):[[:space:]]*$/ {
      current_section = section_name($0)
      section_indent = indent
      next
    }

    current_section != "" {
      if (indent <= section_indent) {
        current_section = ""
        section_indent = -1
      }
    }

    current_section != "" {
      if ($0 ~ /^[[:space:]]*(type|kind):[[:space:]]*/) {
        line = $0
        sub(/^[[:space:]]*(type|kind):[[:space:]]*/, "", line)
        capture_type(current_section, line)
        current_section = ""
        section_indent = -1
      }
    }

    END {
      if (state_type != "") {
        print state_type
      } else if (tracker_type != "") {
        print tracker_type
      }
    }
  ' "$workflow_path"
}

bootstrap="false"
port=""
workflow="$elixir_dir/WORKFLOW.md"

if [[ -f "$env_file" ]]; then
  # Load simple KEY=VALUE entries from the repo-local .env for local runs.
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
fi

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -n "${GH_TOKEN:-}" ]]; then
  export GITHUB_TOKEN="$GH_TOKEN"
fi

if [[ -z "${GH_TOKEN:-}" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

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

workflow="$(resolve_absolute_path "$workflow")"

if ! command -v mise >/dev/null 2>&1; then
  echo "error: 'mise' is required. Install from https://mise.jdx.dev/getting-started.html" >&2
  exit 1
fi

if [[ ! -f "$workflow" ]]; then
  echo "error: workflow file not found: $workflow" >&2
  exit 1
fi

tracker_kind="$(extract_state_type "$workflow")"

if [[ "$tracker_kind" == "github" ]] && [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "error: GITHUB_TOKEN is not set." >&2
  echo "run: export GITHUB_TOKEN=..." >&2
  echo "set it in .env, export GITHUB_TOKEN=..., or export GH_TOKEN=..." >&2
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
