#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_EXPERIMENT_NAME_LINT_ROOT:-$(dirname "$SCRIPT_DIR")}"
ALLOWLIST_FILE="${VIBE_EXPERIMENT_NAME_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/tracked_experiment_name_allowlist.txt}"
VALID_CATEGORIES="gate bench-fixture manual-experiment archive-candidate"

if [ ! -d "$PROJECT_ROOT/.git" ]; then
  echo "experiment-name lint: project root is not a git repository: $PROJECT_ROOT" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_experiment_name_lint.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
violations="$tmp_dir/violations.txt"
allowlist_errors="$tmp_dir/allowlist_errors.txt"
: > "$violations"
: > "$allowlist_errors"

is_candidate_path() {
  local path="$1"
  local base="${path##*/}"

  case "$path" in
    .github/*|lib/*|scripts/*|src/*|vibe/*) ;;
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

validate_allowlist() {
  [ -f "$ALLOWLIST_FILE" ] || return 0

  awk -v categories="$VALID_CATEGORIES" '
    BEGIN {
      split(categories, parts, " ")
      for (i in parts) valid[parts[i]] = 1
    }
    $0 == "" || $1 ~ /^#/ { next }
    NF < 2 {
      printf "%s:%d: missing category (expected one of: %s)\n", FILENAME, FNR, categories
      next
    }
    !valid[$2] {
      printf "%s:%d: invalid category `%s` (expected one of: %s)\n", FILENAME, FNR, $2, categories
      next
    }
  ' "$ALLOWLIST_FILE" >> "$allowlist_errors"

  while read -r path _category _rest; do
    case "${path:-}" in
      ""|\#*) continue ;;
    esac
    if ! git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      printf '%s: stale allowlist entry `%s` (file is not tracked)\n' "$ALLOWLIST_FILE" "$path" \
        >> "$allowlist_errors"
    fi
  done < "$ALLOWLIST_FILE"
}

validate_allowlist

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

if [ -s "$allowlist_errors" ]; then
  echo "experiment-name lint: invalid allowlist" >&2
  cat "$allowlist_errors" >&2
  exit 1
fi

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
echo "Format: <path> <category> [reason], category in: $VALID_CATEGORIES" >&2
exit 1
