#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_ARCH_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_ROOT="${VIBE_ARCH_LINT_ROOT:-$PROJECT_ROOT}"
RULES_FILE="${VIBE_ARCH_LINT_RULES:-$PROJECT_ROOT/scripts/architecture_debt_rules.tsv}"
ALLOWLIST_FILE="${VIBE_ARCH_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/architecture_debt_allowlist.txt}"

if [ ! -d "$SCAN_ROOT" ]; then
  echo "architecture-debt lint: scan root not found: $SCAN_ROOT" >&2
  exit 1
fi
if [ ! -f "$RULES_FILE" ]; then
  echo "architecture-debt lint: rules file not found: $RULES_FILE" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_arch_lint.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
findings="$tmp_dir/findings.tsv"
: > "$findings"

is_allowed() {
  local rule_id="$1"
  local rel_path="$2"
  local line_no="$3"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  awk -F '\t' \
    -v id="$rule_id" \
    -v path="$rel_path" \
    -v line="$line_no" '
      $0 == "" || $1 ~ /^#/ { next }
      $1 == id && $2 == path && ($3 == line || $3 == "*") { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$ALLOWLIST_FILE"
}

while IFS=$'\t' read -r rule_id severity scope pattern message issue rest; do
  case "$rule_id" in
    ""|\#*) continue ;;
  esac
  if [ -n "${rest:-}" ] || [ -z "${issue:-}" ]; then
    echo "architecture-debt lint: invalid rule row for $rule_id" >&2
    exit 1
  fi
  case "$severity" in
    error|warn) ;;
    *)
      echo "architecture-debt lint: invalid severity for $rule_id: $severity" >&2
      exit 1
      ;;
  esac

  set +e
  matches="$(cd "$SCAN_ROOT" && rg --line-number --no-heading --glob "$scope" --regexp "$pattern" . 2>"$tmp_dir/rg.err")"
  rg_status=$?
  set -e
  if [ "$rg_status" -eq 1 ]; then
    continue
  fi
  if [ "$rg_status" -ne 0 ]; then
    echo "architecture-debt lint: rg failed for $rule_id" >&2
    cat "$tmp_dir/rg.err" >&2
    exit "$rg_status"
  fi

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rel_path="${row%%:*}"
    rest_row="${row#*:}"
    line_no="${rest_row%%:*}"
    text="${rest_row#*:}"
    rel_path="${rel_path#./}"
    if is_allowed "$rule_id" "$rel_path" "$line_no"; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$severity" "$rule_id" "$rel_path" "$line_no" "$message" "$issue" "$text" >> "$findings"
  done <<< "$matches"
done < "$RULES_FILE"

if [ ! -s "$findings" ]; then
  echo "architecture-debt lint: ok"
  exit 0
fi

echo "architecture-debt lint: found new violations" >&2
while IFS=$'\t' read -r severity rule_id rel_path line_no message issue text; do
  printf '%s:%s: %s %s: %s (%s)\n' \
    "$rel_path" "$line_no" "$severity" "$rule_id" "$message" "$issue" >&2
  printf '  %s\n' "$text" >&2
done < "$findings"
exit 1
