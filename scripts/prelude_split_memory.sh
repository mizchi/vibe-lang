#!/usr/bin/env bash
# #2510 criterion 5: what the per-module prelude (#2575 item 2) costs in
# allocation, measured on the compiler's own closure.
#
#   bash scripts/prelude_split_memory.sh [corpus] [leaf]
#
# This is a MEASUREMENT, not a gate: it prints numbers and always exits 0, so
# there is no pass/fail property for a `_test.sh` to red-test. That is also why
# it is not named `check_*` / `*_gate` -- scripts/check_gate_self_tests.sh's
# ratchet is for scripts that make a claim, and this one only reports.
#
# The protocol is the one .claude/skills/compiler-perf-profiling insists on,
# because without it the numbers lie (#2393/#2394):
#
#   - ONE lane per process, each with its OWN VIBE_BUILD_CACHE_DIR. Two lanes
#     in one process would let the first warm every persistent cache the
#     second reads; the skill measures that asymmetry at ~8.0s/1.46GB cold vs
#     ~4.7s/727MB warm, larger than anything being compared here.
#   - three temperatures per lane: cold (fresh cache), after a ONE-MODULE
#     edit (the scenario the split exists for), and unchanged-warm.
#   - `heap_delta` comes from `Profiler::heap_bytes`, a BUMP pointer, so it is
#     bytes ALLOCATED across the compile, not bytes live at the end. N=1 per
#     cell is enough BECAUSE of that: the figure is deterministic for a given
#     input and cache state, and reproduced to the byte across runs. Wall time
#     would need N>=3; this does not report wall.
#
# The leaf must really be in the corpus's import closure. It is checked here,
# because the first run of this measurement edited a file that was NOT, and
# every "leaf-edited" number came back byte-identical to the unchanged-warm
# one -- a vacuous experiment that looked like a result.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CORPUS="${1:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
LEAF="${2:-lib/@vibe/core/defaults.vibe}"

for f in "$CORPUS" "$LEAF"; do
  if [ ! -f "$f" ]; then
    echo "prelude_split_memory.sh: not found: $f" >&2
    exit 2
  fi
done

cli="${VIBE_PRELUDE_SPLIT_CLI_WASM:-}"
if [ -z "$cli" ]; then
  cli="$(ls -d _build/selfhost/generations/*/ 2>/dev/null | tail -1)stage2.wasm"
fi
if [ ! -f "$cli" ]; then
  echo "prelude_split_memory.sh: no compiler wasm; set VIBE_PRELUDE_SPLIT_CLI_WASM" >&2
  exit 2
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe_prelude_split.XXXXXX")"
trap 'cp "$tmp_dir/leaf.orig" "$LEAF" 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

# The closure the build actually reads, from the compiler itself -- the same
# query `pkf run test-affected` uses, so it cannot drift from what is compiled.
closure="$tmp_dir/closure.txt"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw VIBE_DEPS=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$cli" "$CORPUS" "$closure" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$closure" ]; then
  echo "prelude_split_memory.sh: could not resolve the closure of $CORPUS" >&2
  exit 2
fi
if ! grep -qx -- "$LEAF" "$closure"; then
  echo "prelude_split_memory.sh: $LEAF is NOT in the import closure of $CORPUS." >&2
  echo "  Editing it would change nothing, and every leaf-edited row would" >&2
  echo "  come back equal to the unchanged one -- a vacuous measurement." >&2
  exit 2
fi
echo "[prelude-split-memory] corpus=$CORPUS closure=$(grep -c . "$closure") leaf=$LEAF"

cp "$LEAF" "$tmp_dir/leaf.orig"

run_one() {
  local lane="$1" cache_dir="$2" label="$3"
  local line
  line="$(VIBE_BUILD_CACHE_DIR="$cache_dir" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/prelude_split_memory.vibex \
    -- "$CORPUS" __no_entry__ "$lane" 2>&1 | grep 'prelude-split-memory' || true)"
  if [ -z "$line" ]; then
    echo "[prelude-split-memory] $label $lane: no measurement line" >&2
    exit 1
  fi
  printf '%-13s %s\n' "$label" "$line"
}

for lane in whole split; do
  cache_dir="$tmp_dir/cache_$lane"
  mkdir -p "$cache_dir"
  run_one "$lane" "$cache_dir" "cold"
  printf '\n// prelude_split_memory.sh measurement touch\n' >> "$LEAF"
  run_one "$lane" "$cache_dir" "leaf-edited"
  cp "$tmp_dir/leaf.orig" "$LEAF"
  run_one "$lane" "$cache_dir" "unchanged"
done
