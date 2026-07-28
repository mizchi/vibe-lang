#!/usr/bin/env bash
# vibe-fmt lint gate: every lib/**/*.vibe file must be a fixpoint of
# the selfhost CST-token formatter (scripts/vibe_fmt.sh --check), UNLESS it's
# listed in the allowlist below.
#
# `pkf run fmt` (scripts/vibe_fmt_apply.sh) applies the formatter across the
# whole tree in write mode; the codebase was bulk-reformatted with it on
# 2026-07-28 and is now a fixpoint. What remains in
# scripts/vibe_fmt_allowlist.txt is a small PERMANENT exception list for
# committed auto-generated bundle artifacts (scripts/generate_bundle.sh's
# compact/minified output), not a ratchet of live debt -- if a new entry
# shows up there for any other reason, treat it as debt: run
# `bash scripts/vibe_fmt.sh <file>`, review the diff, and remove the line
# rather than letting the list grow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_FMT_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_ROOT="${VIBE_FMT_LINT_ROOT:-lib}"
ALLOWLIST_FILE="${VIBE_FMT_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/vibe_fmt_allowlist.txt}"
cd "$PROJECT_ROOT"

if [ ! -d "$SCAN_ROOT" ]; then
  echo "vibe-fmt lint: scan root not found: $SCAN_ROOT" >&2
  exit 1
fi

is_allowed() {
  local rel_path="$1"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  awk -v path="$rel_path" '
    $0 == "" || $1 ~ /^#/ { next }
    $1 == path { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ALLOWLIST_FILE"
}

mapfile -t files < <(git ls-files "$SCAN_ROOT/*.vibe" | sort)

if [ "${#files[@]}" -eq 0 ]; then
  echo "vibe-fmt lint: no tracked .vibe files under $SCAN_ROOT" >&2
  exit 1
fi

new_violations=()
stale_allowlist=()
checked=0
known_debt=0

for rel_path in "${files[@]}"; do
  checked=$((checked + 1))
  if bash scripts/vibe_fmt.sh --check "$rel_path" >/dev/null 2>"/tmp/vibe_fmt_lint_err.$$"; then
    if is_allowed "$rel_path"; then
      stale_allowlist+=("$rel_path")
    fi
  else
    if is_allowed "$rel_path"; then
      known_debt=$((known_debt + 1))
    else
      new_violations+=("$rel_path")
    fi
  fi
  rm -f "/tmp/vibe_fmt_lint_err.$$"
done

status=0

if [ "${#stale_allowlist[@]}" -gt 0 ]; then
  echo "vibe-fmt lint: note -- these allowlist entries now pass --check; remove them from $ALLOWLIST_FILE to shrink the ratchet:" >&2
  printf '  %s\n' "${stale_allowlist[@]}" >&2
fi

if [ "${#new_violations[@]}" -gt 0 ]; then
  echo "vibe-fmt lint: found ${#new_violations[@]} unformatted file(s) not in the allowlist:" >&2
  printf '  %s\n' "${new_violations[@]}" >&2
  echo "vibe-fmt lint: run \`bash scripts/vibe_fmt.sh <file>\` to format, or add a justified entry to $ALLOWLIST_FILE" >&2
  status=1
fi

echo "vibe-fmt lint: checked $checked file(s) under $SCAN_ROOT ($known_debt known debt, ${#new_violations[@]} new violations)"
exit "$status"
