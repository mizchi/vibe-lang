#!/usr/bin/env bash
# vibe-fmt bulk apply: format every tracked lib/**/*.vibe and lib/**/*.vpkg
# file in place (`.vpkg` package contracts go through format_vpkg -- a
# canonical header writer plus the CST formatter over the bodyless
# declarations, #1435), except the small set of AUTO-GENERATED files in
# scripts/vibe_fmt_allowlist.txt (bundle/module-source artifacts
# scripts/generate_bundle.sh emits as compact/minified output -- those
# aren't meant to be hand-formatted). This is the counterpart to
# scripts/check_vibe_fmt.sh (--check, CI-enforced) for actually paying down
# the ratchet: `pkf run fmt` runs this.
#
# The actual formatting runs through scripts/run_vibe_fmt_batch.sh (the
# selfhost CST-token formatter, lib/@vibe/compiler/fmt/format.vibe, driven
# via the batched lib/@vibe/cli/fmt.vibe entry) -- one wasm process for the
# WHOLE file list instead of one process per file, sharded across
# VIBE_FMT_JOBS (default: nproc) subprocesses for real parallelism. See
# lib/@vibe/cli/fmt.vibe's header comment for why: the old per-file
# scripts/vibe_fmt.sh loop spent >95% of its wall time on fixed
# process-spawn/wasm-instantiate overhead, not on formatting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_FMT_LINT_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
SCAN_ROOT="${VIBE_FMT_LINT_ROOT:-lib}"
ALLOWLIST_FILE="${VIBE_FMT_LINT_ALLOWLIST:-$PROJECT_ROOT/scripts/vibe_fmt_allowlist.txt}"
JOBS="${VIBE_FMT_JOBS:-$(nproc 2>/dev/null || echo 1)}"
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

mapfile -t files < <(git ls-files "$SCAN_ROOT/*.vibe" "$SCAN_ROOT/*.vpkg" | sort)

to_format=()
skipped=0
for rel_path in "${files[@]}"; do
  if is_excluded "$rel_path"; then
    skipped=$((skipped + 1))
  else
    to_format+=("$rel_path")
  fi
done

formatted=0
rewritten=0
errors=()
if [ "${#to_format[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r status rel_path message; do
    [ -n "$status" ] || continue
    formatted=$((formatted + 1))
    case "$status" in
      DIFF) rewritten=$((rewritten + 1)) ;;
      ERROR) errors+=("$rel_path: $message") ;;
    esac
  done < <(printf '%s\n' "${to_format[@]}" | bash scripts/run_vibe_fmt_batch.sh write "$JOBS")
fi

if [ "${#errors[@]}" -gt 0 ]; then
  echo "vibe-fmt apply: ${#errors[@]} file(s) errored:" >&2
  printf '  %s\n' "${errors[@]}" >&2
  exit 1
fi

echo "vibe-fmt apply: formatted $formatted file(s) under $SCAN_ROOT ($skipped excluded as auto-generated, $rewritten rewritten)"
