#!/usr/bin/env bash
# vibe-fmt bulk apply: format every tracked lib/**/*.vibe file in place via
# scripts/vibe_fmt.sh (write mode), except the small set of AUTO-GENERATED
# files listed in scripts/vibe_fmt_allowlist.txt (bundle/module-source
# artifacts scripts/generate_bundle.sh emits as compact/minified output --
# those aren't meant to be hand-formatted). This is the counterpart to
# scripts/check_vibe_fmt.sh (--check, CI-enforced) for actually paying down
# the ratchet: `pkf run fmt` runs this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_FMT_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_ROOT="${VIBE_FMT_LINT_ROOT:-lib}"
ALLOWLIST_FILE="${VIBE_FMT_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/vibe_fmt_allowlist.txt}"
cd "$PROJECT_ROOT"

is_excluded() {
  local rel_path="$1"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  awk -v path="$rel_path" '
    $0 == "" || $1 ~ /^#/ { next }
    $1 == path { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ALLOWLIST_FILE"
}

mapfile -t files < <(git ls-files "$SCAN_ROOT/*.vibe" | sort)

formatted=0
skipped=0
for rel_path in "${files[@]}"; do
  if is_excluded "$rel_path"; then
    skipped=$((skipped + 1))
    continue
  fi
  bash scripts/vibe_fmt.sh "$rel_path" >/dev/null
  formatted=$((formatted + 1))
done

echo "vibe-fmt apply: formatted $formatted file(s) under $SCAN_ROOT ($skipped excluded as auto-generated)"
