#!/usr/bin/env bash
# vibe-fmt lint gate: every lib/**/*.vibe and lib/**/*.vpkg file must be a
# fixpoint of the selfhost CST-token formatter, UNLESS it's listed in the
# allowlist below. `.vpkg` package contracts (#1435) go through
# format_vpkg: a canonical header writer plus the same CST formatter over
# the bodyless declarations below it -- the header is not vibe syntax, so
# it cannot go through format_script (see format.vibe's `.vpkg` section).
# Runs through scripts/run_vibe_fmt_batch.sh (one batched wasm
# process for the whole file list, sharded across VIBE_FMT_JOBS
# subprocesses) instead of one scripts/vibe_fmt.sh process per file --
# see lib/@vibe/cli/fmt.vibe's header comment for why that matters at
# ~750+ tracked files.
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
JOBS="${VIBE_FMT_JOBS:-$(nproc 2>/dev/null || echo 1)}"
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

mapfile -t files < <(git ls-files "$SCAN_ROOT/*.vibe" "$SCAN_ROOT/*.vpkg" | sort)

if [ "${#files[@]}" -eq 0 ]; then
  echo "vibe-fmt lint: no tracked .vibe/.vpkg files under $SCAN_ROOT" >&2
  exit 1
fi

# Skip allowlisted files BEFORE batching instead of filtering their report
# lines afterwards. The allowlist holds generate_bundle.sh's committed
# artifacts (compact/minified multi-MB flattened sources); running those
# through the formatter is pointless work, and the largest one
# (_cli_adapter_module_source.vibe, ~4MB) overflows the fmt wasm's bump
# allocator past the 2GB i32 boundary and takes its whole SHARD down --
# every co-sharded file then reports "shard produced no report".
# Tradeoff: a stale allowlist entry (one that would now pass --check) is
# no longer detected; entries are few and reviewed by hand.
checked_files=()
known_debt=0
for f in "${files[@]}"; do
  if is_allowed "$f"; then
    known_debt=$((known_debt + 1))
  else
    checked_files+=("$f")
  fi
done
files=("${checked_files[@]}")

new_violations=()
stale_allowlist=()
errors=()
checked=0

while IFS=$'\t' read -r status rel_path message; do
  [ -n "$status" ] || continue
  checked=$((checked + 1))
  if [ "$status" = "OK" ]; then
    if is_allowed "$rel_path"; then
      stale_allowlist+=("$rel_path")
    fi
    continue
  fi
  if [ "$status" = "ERROR" ]; then
    errors+=("$rel_path: $message")
  fi
  if is_allowed "$rel_path"; then
    known_debt=$((known_debt + 1))
  else
    new_violations+=("$rel_path")
  fi
done < <(printf '%s\n' "${files[@]}" | bash scripts/run_vibe_fmt_batch.sh check "$JOBS")

# A process substitution's exit status is not this script's, so a batch that
# died -- the formatter would not build, a shard produced no report -- fed
# the loop zero lines and every count below stayed 0: "checked 0 file(s)",
# exit 0, a green that inspected nothing (#2271, same family as the silent
# rc-1 loop it fixes). Every file handed to the batch must come back.
if [ "$checked" -ne "${#files[@]}" ]; then
  echo "vibe-fmt lint: the batch reported on $checked of ${#files[@]} file(s); the rest were never checked" >&2
  echo "  this is NOT a formatting verdict -- see the batch's diagnostics above" >&2
  exit 2
fi

if [ "${#errors[@]}" -gt 0 ]; then
  echo "vibe-fmt lint: ${#errors[@]} file(s) errored while checking (not merely unformatted):" >&2
  printf '  %s\n' "${errors[@]}" >&2
fi

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
