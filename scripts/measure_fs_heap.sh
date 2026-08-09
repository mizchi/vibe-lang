#!/usr/bin/env bash
# measure_fs_heap.sh — cold/warm guest-memory measurement of the FS-mode
# whole-CLI compile (#1553).
#
# This compiles lib/@vibe/cli/main.vibex with a pinned base compiler,
# VIBE_FS_COMPILE=1, a selected VIBE_RC lane, and VIBE_PROFILE_MEMORY_MARKS=1. The runner
# emits one `[profile-memory]` line for each explicit compiler boundary. The
# deterministic measurements are `pages` (guest linear-memory pages) and
# `heap_ptr` (guest bump-heap high-water); RSS is printed only as a host
# diagnostic and must not be used as a gate.
#
# Boundary labels are deliberately call-boundary names, not inferred phases:
#   start, source_groups, prepared_db, merged_stmts, codegen_rc|codegen_bump,
#   write_output, fs_compile_complete.
# They do not claim separately unobservable normalize or link work.
#
# ISOLATION CONTRACT
#   Each invocation creates a unique run directory below VIBE_FS_HEAP_OUT_DIR
#   for its cache, output wasm, and runner logs. It deletes that directory on
#   exit unless VIBE_FS_HEAP_KEEP_RUN_DIR=1. --cold always starts with an empty
#   cache. --warm snapshots its persistent warm cache into the unique run
#   directory, then atomically refreshes the snapshot after a successful run.
#   Warm runs take an exclusive cache lock; VIBE_FS_HEAP_LOCK_DIR optionally
#   requests the same exclusion for cold runs.
#
# GATE
#   --gate (or VIBE_FS_HEAP_MAX_PAGES) fails when the peak guest pages exceed
#   the configured limit. --gate's default is 57344 pages = 3.5 GiB. This is
#   intentionally opt-in: a cold full-CLI compile is too costly to add to an
#   always-on CI lane without recorded timing/cost data.
#
# USAGE
#   bash scripts/measure_fs_heap.sh --cold [--backend rc|bump] [--base stage2.wasm] [--gate]
#   bash scripts/measure_fs_heap.sh --warm [--backend rc|bump] [--base stage2.wasm]
#   bash scripts/measure_fs_heap.sh --cold --backend rc --verify-parity --base stage2.wasm
#
# --backend selects the marked RC (default) or bump codegen twin. --verify-parity
# performs a second, independently cold unmarked compile in that same lane and
# fails unless its wasm bytes exactly match the marked compile. It is also
# opt-in because it doubles the already-expensive full-CLI work.
#
# Output is stdout-only and grep-able:
#   [fs-heap] mode=cold backend=rc boundary=... heap_mib=... pages=... mem_mib=... rss_mib=...
#   [fs-heap] mode=cold backend=rc peak_heap_mib=... peak_pages=... headroom_mib=... wall_s=...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

MODE=warm
BACKEND=rc
BASE_COMPILER="${VIBE_MEASURE_BASE_COMPILER:-}"
VERIFY_PARITY=0
GATE=0
MAX_PAGES="${VIBE_FS_HEAP_MAX_PAGES:-}"
OUT_DIR="${VIBE_FS_HEAP_OUT_DIR:-$PROJECT_ROOT/_build/measure_fs_heap}"
RUNNER="${VIBE_FS_HEAP_RUNNER:-$SCRIPT_DIR/run_wasm_vibe_host_runner.sh}"
KEEP_RUN_DIR="${VIBE_FS_HEAP_KEEP_RUN_DIR:-0}"
RUN_DIR=""
WARM_NEXT=""
LOCK_DIR=""
LOCK_HELD=0
ACTIVE_PID=""

# Also sanitize the artifact-preparation step below: it executes the same host
# runner and must not inherit controls that would perturb a later measurement.
unset VIBE_WASM_PRE_GROW_PAGES VIBE_WASM_HOST_ALLOC_MODE \
  VIBE_WASM_HOST_ARENA_GUARD_BYTES VIBE_WASM_MEMORY_STATS \
  VIBE_WASM_NAMES VIBE_WASM_KEEP_EXPORTS VIBE_ENTRY_TESTMETA_OUT \
  VIBE_TESTMETA_OUT VIBE_PROFILE_MEMORY_MARK VIBE_ARTIFACT_INPUT_TRACE_OUT \
  VIBE_ARTIFACT_INPUT_TRACE_NONCE VIBE_INGESTION_TELEMETRY_OUT \
  VIBE_INGESTION_TELEMETRY_NONCE VIBE_INCREMENTAL_TELEMETRY_OUT \
  VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE \
  VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP \
  VIBE_DIAGNOSTICS_ALL VIBE_SCHEDULER_TRACE VIBE_DEP_ORDER_SEED \
  VIBE_RC_HEAP_START VIBE_RC_FL_WINDOW VIBE_RC_POISON_MASK VIBE_CFG \
  VIBE_BACKEND VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE VIBE_CHECK_ONLY VIBE_LSP \
  VIBE_HASH VIBE_HASH_WRITE VIBE_MISSING_VPKG_SCAN VIBE_DEPS_MISSING_SCAN \
  VIBE_FILL_PINS VIBE_PUBLISH_CHECK VIBE_MODULE_JOB_DIR VIBE_PUBLISH_ENV_CACHE \
  VIBE_LIST_DEPS VIBE_MODULE_PLAN VIBE_RC VIBE_COVERAGE VIBE_DEBUG \
  VIBE_DEBUG_BREAK VIBE_IMPORT_ABI VIBE_BUILD_CACHE_DIR VIBE_NODE_WASM_FLAGS \
  VIBE_PROFILE_MEMORY_MARKS VIBE_PREOPEN_DIR VIBE_INPUT VIBE_OUTPUT VIBE_ENTRY \
  VIBE_FORCE_RUN_INIT

usage() {
  sed -n '1,45p' "$0" >&2
}

cleanup() {
  local status=$?
  if [ -n "$WARM_NEXT" ]; then
    rm -rf "$WARM_NEXT"
  fi
  if [ "$LOCK_HELD" = 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ -n "$RUN_DIR" ] && [ "$KEEP_RUN_DIR" != 1 ]; then
    rm -rf "$RUN_DIR"
  fi
  exit "$status"
}

on_signal() {
  local status="$1"
  trap - HUP INT TERM
  if [ -n "$ACTIVE_PID" ]; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
    ACTIVE_PID=""
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --cold) MODE=cold; shift ;;
    --warm) MODE=warm; shift ;;
    --backend)
      [ $# -ge 2 ] || { echo "measure_fs_heap: --backend requires rc or bump" >&2; exit 2; }
      BACKEND="$2"; shift 2 ;;
    --base)
      [ $# -ge 2 ] || { echo "measure_fs_heap: --base requires a wasm path" >&2; exit 2; }
      BASE_COMPILER="$2"; shift 2 ;;
    --gate) GATE=1; shift ;;
    --verify-parity) VERIFY_PARITY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "measure_fs_heap: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$BACKEND" in
  rc|bump) ;;
  *)
    echo "measure_fs_heap: --backend must be rc or bump" >&2
    exit 2
    ;;
esac

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
# Warm snapshot updates share state; cold runs are independent unless an
# operator explicitly requests a host-resource lock.
if [ "$MODE" = warm ]; then
  LOCK_DIR="${VIBE_FS_HEAP_LOCK_DIR:-$OUT_DIR/.warm-cache.lock}"
elif [ -n "${VIBE_FS_HEAP_LOCK_DIR:-}" ]; then
  LOCK_DIR="$VIBE_FS_HEAP_LOCK_DIR"
fi
if [ -n "$LOCK_DIR" ]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "measure_fs_heap: another measurement holds lock: $LOCK_DIR" >&2
    exit 1
  fi
  LOCK_HELD=1
fi
RUN_DIR="$(mktemp -d "$OUT_DIR/run.XXXXXX")"

# The full CLI import graph references the ignored, deterministically generated
# compiler bundles. A direct opt-in measurement must prepare them too; otherwise
# a clean checkout would fail before reaching a memory boundary. These are build
# outputs only and remain outside the commit.
bash "$SCRIPT_DIR/ensure_generated.sh" >&2

if [ -z "$BASE_COMPILER" ]; then
  BASE_COMPILER="$RUN_DIR/base_compiler.wasm"
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

MARKED_CACHE="$RUN_DIR/cache_marked_$BACKEND"
if [ "$MODE" = warm ] && [ -d "$OUT_DIR/warm-cache_$BACKEND" ]; then
  cp -a "$OUT_DIR/warm-cache_$BACKEND/." "$MARKED_CACHE"
else
  mkdir -p "$MARKED_CACHE"
fi
MARKED_OUT="$RUN_DIR/cli_core_marked_$BACKEND.wasm"
MARKED_LOG="$RUN_DIR/marked_$BACKEND.log"
CODEGEN_BOUNDARY="codegen_$BACKEND"
RC_VALUE=1
if [ "$BACKEND" = bump ]; then
  RC_VALUE=0
fi

echo "[fs-heap] mode=$MODE backend=$BACKEND base=$BASE_COMPILER entry=$ENTRY_REL run_dir=$RUN_DIR" >&2

run_compile() {
  local marks="$1"
  local cache_dir="$2"
  local output="$3"
  local log="$4"
  # Pin one FS backend. env -u prevents host-runner allocation controls,
  # alternate compiler modes, sidecars, and observability from contaminating
  # the measured heap/pages or silently selecting a different compile path.
  exec env \
    -u VIBE_WASM_PRE_GROW_PAGES \
    -u VIBE_WASM_HOST_ALLOC_MODE \
    -u VIBE_WASM_HOST_ARENA_GUARD_BYTES \
    -u VIBE_WASM_MEMORY_STATS \
    -u VIBE_WASM_NAMES \
    -u VIBE_WASM_KEEP_EXPORTS \
    -u VIBE_ENTRY_TESTMETA_OUT \
    -u VIBE_TESTMETA_OUT \
    -u VIBE_PROFILE_MEMORY_MARK \
    -u VIBE_ARTIFACT_INPUT_TRACE_OUT \
    -u VIBE_ARTIFACT_INPUT_TRACE_NONCE \
    -u VIBE_INGESTION_TELEMETRY_OUT \
    -u VIBE_INGESTION_TELEMETRY_NONCE \
    -u VIBE_INCREMENTAL_TELEMETRY_OUT \
    -u VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT \
    -u VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE \
    -u VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP \
    -u VIBE_DIAGNOSTICS_ALL \
    -u VIBE_SCHEDULER_TRACE \
    -u VIBE_DEP_ORDER_SEED \
    -u VIBE_RC_HEAP_START \
    -u VIBE_RC_FL_WINDOW \
    -u VIBE_RC_POISON_MASK \
    -u VIBE_CFG \
    -u VIBE_BACKEND \
    -u VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE \
    -u VIBE_CHECK_ONLY \
    -u VIBE_LSP \
    -u VIBE_HASH \
    -u VIBE_HASH_WRITE \
    -u VIBE_MISSING_VPKG_SCAN \
    -u VIBE_DEPS_MISSING_SCAN \
    -u VIBE_FILL_PINS \
    -u VIBE_PUBLISH_CHECK \
    -u VIBE_MODULE_JOB_DIR \
    -u VIBE_PUBLISH_ENV_CACHE \
    -u VIBE_LIST_DEPS \
    -u VIBE_MODULE_PLAN \
    -u VIBE_EMIT_MERGED_SOURCE \
    -u VIBE_EMIT_MODULE_SOURCE \
    VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_IMPORT_ABI=raw \
    VIBE_FS_COMPILE=1 VIBE_RC="$RC_VALUE" VIBE_CHECK_ERROR_ROW=1 \
    VIBE_COVERAGE=0 VIBE_DEBUG_BREAK=0 VIBE_DEBUG=0 \
    VIBE_BUILD_CACHE_DIR="$cache_dir" VIBE_PROFILE_MEMORY_MARKS="$marks" \
    bash "$RUNNER" --invoke cli_main "$BASE_COMPILER" "$ENTRY_REL" "$output" main \
    2>"$log" >/dev/null
}

start_s=$(date +%s)
set +e
run_compile 1 "$MARKED_CACHE" "$MARKED_OUT" "$MARKED_LOG" &
ACTIVE_PID=$!
wait "$ACTIVE_PID"
status=$?
ACTIVE_PID=""
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
awk -v mode="$MODE" -v backend="$BACKEND" -v codegen_boundary="$CODEGEN_BOUNDARY" -v wall="$((end_s - start_s))" -v max_pages="$MAX_PAGES" '
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
    printf "[fs-heap] mode=%s backend=%s boundary=%s heap_mib=%.1f delta_mib=%.1f pages=%d mem_mib=%.1f rss_mib=%.1f\n", \
      mode, backend, name, heap / 1048576, (heap - prev_heap) / 1048576, pages, bytes / 1048576, rss / 1048576
    prev_heap = heap
    if (heap + 0 > peak_heap) { peak_heap = heap + 0 }
    if (pages + 0 > peak_pages) { peak_pages = pages + 0 }
  }
  END {
    required["start"] = 1
    required["source_groups"] = 1
    required["prepared_db"] = 1
    required["merged_stmts"] = 1
    required[codegen_boundary] = 1
    required["write_output"] = 1
    required["fs_compile_complete"] = 1
    for (name in required) {
      if (!(name in seen_name)) error("missing required boundary mark: " name)
    }
    if (peak_pages == "") error("no valid named [profile-memory] marks in runner stderr")
    if (!failed) {
      printf "[fs-heap] mode=%s backend=%s peak_heap_mib=%.1f peak_pages=%d headroom_mib=%.1f wall_s=%d\n", \
        mode, backend, peak_heap / 1048576, peak_pages, (65536 - peak_pages) * 64 / 1024, wall
      if (max_pages != "" && peak_pages > max_pages) {
        error("GATE FAIL: peak_pages " peak_pages " > limit " max_pages " (3.5 GiB default is 57344 pages)")
      }
    }
    exit(failed ? 1 : 0)
  }
' "$MARKED_LOG"

if [ "$VERIFY_PARITY" = 1 ]; then
  UNMARKED_CACHE="$RUN_DIR/cache_unmarked_$BACKEND"
  UNMARKED_OUT="$RUN_DIR/cli_core_unmarked_$BACKEND.wasm"
  UNMARKED_LOG="$RUN_DIR/unmarked_$BACKEND.log"
  mkdir -p "$UNMARKED_CACHE"
  set +e
  run_compile 0 "$UNMARKED_CACHE" "$UNMARKED_OUT" "$UNMARKED_LOG" &
  ACTIVE_PID=$!
  wait "$ACTIVE_PID"
  status=$?
  ACTIVE_PID=""
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
  echo "[fs-heap] parity=ok mode=$MODE backend=$BACKEND"
fi

# Publish a warm cache only after every requested check passed. The run cache
# itself is always unique; this snapshot is the sole shared warm state and is
# covered by the warm-run lock above.
if [ "$MODE" = warm ]; then
  WARM_NEXT="$(mktemp -d "$OUT_DIR/.warm-cache_$BACKEND.next.XXXXXX")"
  cp -a "$MARKED_CACHE/." "$WARM_NEXT"
  rm -rf "$OUT_DIR/warm-cache_$BACKEND"
  mv "$WARM_NEXT" "$OUT_DIR/warm-cache_$BACKEND"
  WARM_NEXT=""
fi

if [ "$KEEP_RUN_DIR" = 1 ]; then
  echo "[fs-heap] run_dir=$RUN_DIR" >&2
fi
