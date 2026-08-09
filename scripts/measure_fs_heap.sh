#!/usr/bin/env bash
# measure_fs_heap.sh — cold/warm guest-memory measurement of the FS-mode
# whole-CLI compile (#1553).
#
# This compiles lib/@vibe/cli/main.vibex with a current-tree base compiler,
# VIBE_FS_COMPILE=1, VIBE_RC=1, and VIBE_PROFILE_MEMORY_MARKS=1. The runner
# emits one `[profile-memory]` line for each explicit compiler boundary. The
# deterministic measurements are `pages` (guest linear-memory pages) and
# `heap_ptr` (guest bump-heap high-water); RSS is printed only as a host
# diagnostic and must not be used as a gate.
#
# Boundary labels are deliberately call-boundary names, not inferred phases:
#   start, source_groups, prepared_db, merged_stmts, codegen_rc,
#   write_output, fs_compile_complete.
# They do not claim separately unobservable normalize or link work.
#
# COLD CACHE CONTRACT
#   --cold uses a newly-created VIBE_BUILD_CACHE_DIR below the measurement
#   output directory. It never reads an ambient VIBE_BUILD_CACHE_DIR or the
#   repository's shared _build/vibe_* cache. That makes a cold result suitable
#   for comparing commits. --warm uses a separate, persistent cache under the
#   same output directory; first use is necessarily cold.
#
# GATE
#   --gate (or VIBE_FS_HEAP_MAX_PAGES) fails when the peak guest pages exceed
#   the configured limit. --gate's default is 57344 pages = 3.5 GiB. This is
#   intentionally opt-in: a cold full-CLI compile is too costly to add to an
#   always-on CI lane without recorded timing/cost data. Promotion procedure:
#   record repeated cold runs and their cost, commit a baseline/rationale, then
#   add `pkf run measure-fs-heap -- --cold --gate --base <stage2.wasm>` to the
#   existing compiler-gate job, reusing its freshly-built stage2 artifact.
#
# USAGE
#   bash scripts/measure_fs_heap.sh --cold [--base stage2.wasm] [--gate]
#   bash scripts/measure_fs_heap.sh --warm [--base stage2.wasm]
#   bash scripts/measure_fs_heap.sh --cold --verify-parity --base stage2.wasm
#
# --verify-parity performs a second, independently cold unmarked RC compile
# and fails unless its wasm bytes exactly match the marked compile. It is also
# opt-in because it doubles the already-expensive full-CLI work.
#
# Output is stdout-only and grep-able:
#   [fs-heap] mode=cold boundary=... heap_mib=... pages=... mem_mib=... rss_mib=...
#   [fs-heap] mode=cold peak_heap_mib=... peak_pages=... headroom_mib=... wall_s=...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

MODE=warm
BASE_COMPILER="${VIBE_MEASURE_BASE_COMPILER:-}"
VERIFY_PARITY=0
GATE=0
MAX_PAGES="${VIBE_FS_HEAP_MAX_PAGES:-}"
OUT_DIR="${VIBE_FS_HEAP_OUT_DIR:-$PROJECT_ROOT/_build/measure_fs_heap}"
RUNNER="${VIBE_FS_HEAP_RUNNER:-$SCRIPT_DIR/run_wasm_vibe_host_runner.sh}"

usage() {
  sed -n '1,48p' "$0" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cold) MODE=cold; shift ;;
    --warm) MODE=warm; shift ;;
    --base)
      [ $# -ge 2 ] || { echo "measure_fs_heap: --base requires a wasm path" >&2; exit 2; }
      BASE_COMPILER="$2"; shift 2 ;;
    --gate) GATE=1; shift ;;
    --verify-parity) VERIFY_PARITY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "measure_fs_heap: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$GATE" = 1 ] && [ -z "$MAX_PAGES" ]; then
  MAX_PAGES=57344
fi
if [ -n "$MAX_PAGES" ]; then
  case "$MAX_PAGES" in
    *[!0-9]*|0)
      echo "measure_fs_heap: VIBE_FS_HEAP_MAX_PAGES must be a positive integer" >&2
      exit 2
      ;;
  esac
fi
if [ ! -x "$RUNNER" ]; then
  echo "measure_fs_heap: runner is not executable: $RUNNER" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

# The full CLI import graph references the ignored, deterministically generated
# compiler bundles. A direct opt-in measurement must prepare them too; otherwise
# a clean checkout would fail before reaching a memory boundary. These are build
# outputs only and remain outside the commit.
bash "$SCRIPT_DIR/ensure_generated.sh" >&2

if [ -z "$BASE_COMPILER" ]; then
  BASE_COMPILER="$OUT_DIR/base_compiler.wasm"
  echo "[fs-heap] building base compiler from current tree -> $BASE_COMPILER" >&2
  bash "$SCRIPT_DIR/build_cli_wasm.sh" "$BASE_COMPILER" >&2
fi
if [ ! -s "$BASE_COMPILER" ]; then
  echo "measure_fs_heap: base compiler not found: $BASE_COMPILER" >&2
  exit 1
fi

ENTRY_REL="lib/@vibe/cli/main.vibex"
if [ ! -f "$ENTRY_REL" ]; then
  echo "measure_fs_heap: full CLI entry not found: $ENTRY_REL" >&2
  exit 1
fi

# Do not trust an ambient cache override: the cache paths are the experimental
# control, so the script owns them. Cold removes the complete cache root;
# warm preserves only its own prior measurements.
MARKED_CACHE="$OUT_DIR/cache_${MODE}_marked"
if [ "$MODE" = cold ]; then
  rm -rf "$MARKED_CACHE"
fi
mkdir -p "$MARKED_CACHE"
MARKED_OUT="$OUT_DIR/cli_core_${MODE}_marked.wasm"
MARKED_LOG="$OUT_DIR/run_${MODE}_marked.log"
rm -f "$MARKED_OUT" "$MARKED_OUT.diag" "$MARKED_LOG"

echo "[fs-heap] mode=$MODE base=$BASE_COMPILER entry=$ENTRY_REL cache=$MARKED_CACHE" >&2

run_compile() {
  local marks="$1"
  local cache_dir="$2"
  local output="$3"
  local log="$4"
  # Pin the normal RC FS lane; an ambient coverage/debug selector would choose
  # a different compiler entry and fail the required-boundary check.
  VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_RC=1 \
    VIBE_COVERAGE=0 VIBE_DEBUG_BREAK=0 VIBE_DEBUG=0 \
    VIBE_BUILD_CACHE_DIR="$cache_dir" VIBE_PROFILE_MEMORY_MARKS="$marks" \
    bash "$RUNNER" --invoke cli_main "$BASE_COMPILER" "$ENTRY_REL" "$output" main \
    2>"$log" >/dev/null
}

start_s=$(date +%s)
set +e
run_compile 1 "$MARKED_CACHE" "$MARKED_OUT" "$MARKED_LOG"
status=$?
set -e
end_s=$(date +%s)
if [ "$status" -ne 0 ]; then
  echo "measure_fs_heap: marked full-CLI compile failed (exit $status); last stderr lines:" >&2
  tail -20 "$MARKED_LOG" >&2 || true
  exit "$status"
fi
if [ ! -s "$MARKED_OUT" ]; then
  echo "measure_fs_heap: marked full-CLI compile produced no output wasm" >&2
  exit 1
fi
magic="$(od -An -t x1 -N 4 "$MARKED_OUT" | tr -d ' \n')"
if [ "$magic" != "0061736d" ]; then
  echo "measure_fs_heap: marked full-CLI output is not wasm (magic=$magic)" >&2
  exit 1
fi

# Fail closed: a completed compile must expose every documented boundary and
# every required guest metric. The awk program also applies the optional
# page-limit gate to the maximum observed guest page count.
awk -v mode="$MODE" -v wall="$((end_s - start_s))" -v max_pages="$MAX_PAGES" '
  function error(message) {
    print "[fs-heap] ERROR: " message > "/dev/stderr"
    failed = 1
  }
  /^\[profile-memory\] / && / name=/ {
    heap = ""; pages = ""; bytes = ""; rss = ""; name = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^heap_ptr=/) { heap = substr($i, 10) }
      else if ($i ~ /^pages=/) { pages = substr($i, 7) }
      else if ($i ~ /^bytes=/) { bytes = substr($i, 7) }
      else if ($i ~ /^rss=/) { rss = substr($i, 5) }
      else if ($i ~ /^name=/) { name = substr($i, 6) }
    }
    if (name == "" || heap !~ /^[0-9]+$/ || pages !~ /^[0-9]+$/ || bytes !~ /^[0-9]+$/ || rss !~ /^[0-9]+$/) {
      error("malformed named [profile-memory] mark")
      next
    }
    if (seen_name[name]++) {
      error("duplicate boundary mark: " name)
      next
    }
    printf "[fs-heap] mode=%s boundary=%s heap_mib=%.1f delta_mib=%.1f pages=%d mem_mib=%.1f rss_mib=%.1f\n", \
      mode, name, heap / 1048576, (heap - prev_heap) / 1048576, pages, bytes / 1048576, rss / 1048576
    prev_heap = heap
    if (heap + 0 > peak_heap) { peak_heap = heap + 0 }
    if (pages + 0 > peak_pages) { peak_pages = pages + 0 }
  }
  END {
    required["start"] = 1
    required["source_groups"] = 1
    required["prepared_db"] = 1
    required["merged_stmts"] = 1
    required["codegen_rc"] = 1
    required["write_output"] = 1
    required["fs_compile_complete"] = 1
    for (name in required) {
      if (!(name in seen_name)) error("missing required boundary mark: " name)
    }
    if (peak_pages == "") error("no valid named [profile-memory] marks in runner stderr")
    if (!failed) {
      printf "[fs-heap] mode=%s peak_heap_mib=%.1f peak_pages=%d headroom_mib=%.1f wall_s=%d\n", \
        mode, peak_heap / 1048576, peak_pages, (65536 - peak_pages) * 64 / 1024, wall
      if (max_pages != "" && peak_pages > max_pages) {
        error("GATE FAIL: peak_pages " peak_pages " > limit " max_pages " (3.5 GiB default is 57344 pages)")
      }
    }
    exit(failed ? 1 : 0)
  }
' "$MARKED_LOG"

if [ "$VERIFY_PARITY" = 1 ]; then
  UNMARKED_CACHE="$OUT_DIR/cache_${MODE}_unmarked"
  UNMARKED_OUT="$OUT_DIR/cli_core_${MODE}_unmarked.wasm"
  UNMARKED_LOG="$OUT_DIR/run_${MODE}_unmarked.log"
  rm -rf "$UNMARKED_CACHE"
  mkdir -p "$UNMARKED_CACHE"
  rm -f "$UNMARKED_OUT" "$UNMARKED_OUT.diag" "$UNMARKED_LOG"
  set +e
  run_compile 0 "$UNMARKED_CACHE" "$UNMARKED_OUT" "$UNMARKED_LOG"
  status=$?
  set -e
  if [ "$status" -ne 0 ] || [ ! -s "$UNMARKED_OUT" ]; then
    echo "measure_fs_heap: unmarked parity compile failed (exit $status)" >&2
    tail -20 "$UNMARKED_LOG" >&2 || true
    exit 1
  fi
  if ! cmp -s "$MARKED_OUT" "$UNMARKED_OUT"; then
    echo "measure_fs_heap: parity failure: marked and unmarked full-CLI wasm differ" >&2
    exit 1
  fi
  echo "[fs-heap] parity=ok mode=$MODE marked=$MARKED_OUT unmarked=$UNMARKED_OUT"
fi
