#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_EXPERIMENT_NAME_LINT_ROOT:-$(dirname "$SCRIPT_DIR")}"
ALLOWLIST_FILE="${VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/tracked_experiment_name_allowlist.txt}"

if [ ! -d "$PROJECT_ROOT/.git" ]; then
  echo "experiment-name lint: project root is not a git repository: $PROJECT_ROOT" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_experiment_name_lint.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
violations="$tmp_dir/violations.txt"
: > "$violations"

is_candidate_path() {
  local path="$1"
  local base="${path##*/}"

  case "$path" in
    .github/*|scripts/*|src/*|vibe/*) ;;
    *) return 1 ;;
  esac

  case "$base" in
    .tmp_*|*probe*) return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed() {
  local path="$1"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  awk -v path="$path" '
    $0 == "" || $1 ~ /^#/ { next }
    $1 == path { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ALLOWLIST_FILE"
}

while IFS= read -r path; do
  [ -n "$path" ] || continue
  if ! is_candidate_path "$path"; then
    continue
  fi
  if is_allowed "$path"; then
    continue
  fi
  printf '%s\n' "$path" >> "$violations"
done < <(git -C "$PROJECT_ROOT" ls-files)

if [ ! -s "$violations" ]; then
  echo "experiment-name lint: ok"
  exit 0
fi

echo "experiment-name lint: tracked throwaway/probe-like files need an explicit allowlist entry" >&2
while IFS= read -r path; do
  printf '  %s\n' "$path" >&2
done < "$violations"
echo "" >&2
echo "Add intentional gate/bench fixtures to: $ALLOWLIST_FILE" >&2
exit 1
