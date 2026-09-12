#!/usr/bin/env bash
# #2669 step 2b: what a warm build reuses after a one-module edit, measured on
# the compiler's own closure.
#
#   bash scripts/body_cache_reuse.sh [corpus] [leaf]
#
# This is a MEASUREMENT, not a gate: it prints numbers and always exits 0, so
# there is no pass/fail property for a `_test.sh` to red-test. That is also why
# it is not named `check_*` / `*_gate` (scripts/check_gate_self_tests.sh's
# ratchet is for scripts that make a claim).
#
# Protocol, from .claude/skills/compiler-perf-profiling:
#
#   - ONE temperature per process. The three runs share a VIBE_BUILD_CACHE_DIR
#     on purpose -- warm reuse is the thing being measured -- but nothing else
#     may warm it first, so the directory is created fresh here.
#   - `heap_delta` comes from `Profiler::heap_bytes`, a bump pointer, so it is
#     bytes ALLOCATED across the compile. Deterministic for a given input and
#     cache state, which is why N=1 is enough for it; wall time is not
#     reported, because it would not be.
#
# The leaf must really be in the corpus's import closure. Checked here, because
# a leaf outside it makes every "edited" row come back equal to the unchanged
# one -- a vacuous experiment that looks like a result.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CORPUS="${1:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
LEAF="${2:-lib/@vibe/core/defaults.vibe}"
MODE="${VIBE_BODY_CACHE_REUSE_MODE:-on}"

for f in "$CORPUS" "$LEAF"; do
  if [ ! -f "$f" ]; then
    echo "body_cache_reuse.sh: not found: $f" >&2
    exit 2
  fi
done

cli="${VIBE_BODY_CACHE_REUSE_CLI_WASM:-}"
if [ -z "$cli" ]; then
  cli="$(ls -d _build/selfhost/generations/*/ 2>/dev/null | tail -1)stage2.wasm"
fi
if [ ! -f "$cli" ]; then
  echo "body_cache_reuse.sh: no compiler wasm; set VIBE_BODY_CACHE_REUSE_CLI_WASM" >&2
  exit 2
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_body_cache_reuse.XXXXXX")"
trap 'cp "$tmp_dir/leaf.orig" "$LEAF" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

closure="$tmp_dir/closure.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$cli" "$CORPUS" "$closure" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$closure" ]; then
  echo "body_cache_reuse.sh: could not resolve the closure of $CORPUS" >&2
  exit 2
fi
if ! grep -qx -- "$LEAF" "$closure"; then
  echo "body_cache_reuse.sh: $LEAF is NOT in the import closure of $CORPUS." >&2
  echo "  Editing it would change nothing, and every edited row would come" >&2
  echo "  back equal to the unchanged one -- a vacuous measurement." >&2
  exit 2
fi
echo "[body-cache-reuse] corpus=$CORPUS closure=$(grep -c . "$closure") leaf=$LEAF mode=$MODE"

cp "$LEAF" "$tmp_dir/leaf.orig"
cache_dir="$tmp_dir/cache"
mkdir -p "$cache_dir"

run_one() {
  local label="$1"
  local line
  line="$(VIBE_BUILD_CACHE_DIR="$cache_dir" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/body_cache_reuse.vibex \
    -- "$CORPUS" __no_entry__ "$MODE" 2>&1 | grep 'body-cache-reuse ' || true)"
  if [ -z "$line" ]; then
    echo "[body-cache-reuse] $label: no measurement line" >&2
    exit 1
  fi
  printf '%-16s %s\n' "$label" "$line"
}

run_one "cold"
# Warm with nothing touched. This row is the ceiling: it is what reuse looks
# like when the file table matches everywhere.
run_one "unchanged"
# A comment keeps the file's statement count, function vector, lambda plan and
# string literals identical, so every layout guard still holds: this is the
# edit shape step 2b covers.
printf '\n// body_cache_reuse.sh measurement touch\n' >> "$LEAF"
run_one "comment-edited"
# Restoring the file is itself an edit -- the artifact now records the touched
# version -- so this row is a second one-file edit, not an unchanged build.
cp "$tmp_dir/leaf.orig" "$LEAF"
run_one "reverted"
