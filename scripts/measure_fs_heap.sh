#!/usr/bin/env bash
# measure_fs_heap.sh — per-phase guest-heap measurement of the FS-mode
# whole-CLI compile (#1553, first checkbox: continuous heap-peak measurement).
#
# WHAT IT MEASURES
#   The stage1 step of scripts/build_cli_core.sh: an already-built base
#   selfhost compiler wasm compiles lib/@vibe/cli/main.vibex under
#   VIBE_FS_COMPILE=1. With VIBE_PROFILE_MEMORY_MARKS=1 the compiler takes the
#   heap-marked RC lane (compile_file_fs_mode_rc_heap_marked,
#   lib/@vibe/compiler/entry/compiler/file_compile/file_compile.vibe) and the
#   node runner prints one line per phase boundary:
#     [profile-memory] mark=N pages=P bytes=B heap_ptr=H ... name=<phase>
#   Phases: start / collect_sources / typecheck / parse_merge / codegen_rc.
#   The guest bump allocator never frees, so heap_ptr is the cumulative
#   allocation high-water mark: per-phase delta = that phase's allocation
#   volume and the codegen_rc mark is the run's peak. `pages` is the actual
#   linear-memory size (the wasm32 hard cap is 65536 pages = 4 GiB).
#
# WARM vs COLD
#   warm (default): persistent caches under _build/vibe_* are left alone.
#     After any prior compile of the same tree the type-env / dep-list TSVs
#     hit, so the typecheck phase mostly deserializes cached envs
#     (<2 GiB peak per #1553).
#   --cold: first deletes _build/vibe_selfhost_type_env_v3_*.tsv and
#     _build/vibe_selfhost_dep_list_*.tsv, so every module's type env is
#     re-inferred AND re-serialized (the ~2.6 GiB peak of #1553). The cold
#     run rebuilds those caches — expect it to take minutes and to leave the
#     caches warm again afterwards.
#
# BASE COMPILER
#   Must be built from the CURRENT tree (it has to contain the #1553 marks).
#   Resolution order: --base <wasm> argument, else $VIBE_MEASURE_BASE_COMPILER,
#   else a fresh scripts/build_cli_wasm.sh build into
#   _build/measure_fs_heap/base_compiler.wasm (seed -> stage1 -> stage2,
#   several minutes on a cold tree; cached by lib/ tree hash when clean).
#
# USAGE
#   bash scripts/measure_fs_heap.sh                # warm run
#   bash scripts/measure_fs_heap.sh --cold         # cold run (deletes TSVs)
#   bash scripts/measure_fs_heap.sh --base X.wasm  # reuse a known-good base
#
# OUTPUT (stdout, grep-able; full runner stderr kept in
# _build/measure_fs_heap/run_<mode>.log)
#   [fs-heap] mode=<warm|cold> phase=<name> heap_mib=... delta_mib=... pages=... mem_mib=... rss_mib=...
#   [fs-heap] mode=<warm|cold> peak heap_mib=... pages=... headroom_mib=... wall_s=...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

MODE=warm
BASE_COMPILER="${VIBE_MEASURE_BASE_COMPILER:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --cold) MODE=cold; shift ;;
    --base) BASE_COMPILER="$2"; shift 2 ;;
    *) echo "measure_fs_heap: unknown argument: $1" >&2; exit 1 ;;
  esac
done

OUT_DIR="$PROJECT_ROOT/_build/measure_fs_heap"
mkdir -p "$OUT_DIR"

if [ -z "$BASE_COMPILER" ]; then
  BASE_COMPILER="$OUT_DIR/base_compiler.wasm"
  echo "[fs-heap] building base compiler from current tree -> $BASE_COMPILER" >&2
  bash "$SCRIPT_DIR/build_cli_wasm.sh" "$BASE_COMPILER" >&2
fi
if [ ! -s "$BASE_COMPILER" ]; then
  echo "measure_fs_heap: base compiler not found: $BASE_COMPILER" >&2
  exit 1
fi

if [ "$MODE" = "cold" ]; then
  # Cold = the type-env cache TSVs from #1553 are gone; everything else
  # (artifact caches etc.) is left alone so the run still measures the
  # compile itself, not unrelated cache rebuilds.
  echo "[fs-heap] cold: deleting _build/vibe_selfhost_type_env_v3_*.tsv + _build/vibe_selfhost_dep_list_*.tsv" >&2
  rm -f "$PROJECT_ROOT"/_build/vibe_selfhost_type_env_v3_*.tsv \
    "$PROJECT_ROOT"/_build/vibe_selfhost_dep_list_*.tsv
fi

ENTRY_REL="lib/@vibe/cli/main.vibex"
OUT_WASM="$OUT_DIR/cli_core_${MODE}.wasm"
LOG="$OUT_DIR/run_${MODE}.log"

echo "[fs-heap] mode=$MODE base=$BASE_COMPILER entry=$ENTRY_REL" >&2
start_s=$(date +%s)
set +e
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 VIBE_PROFILE_MEMORY_MARKS=1 \
  bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main \
  "$BASE_COMPILER" \
  "$ENTRY_REL" \
  "_build/measure_fs_heap/cli_core_${MODE}.wasm" \
  main 2>"$LOG" >/dev/null
status=$?
set -e
end_s=$(date +%s)
if [ "$status" -ne 0 ]; then
  echo "measure_fs_heap: compile failed (exit $status); last stderr lines:" >&2
  tail -20 "$LOG" >&2
  exit "$status"
fi
if [ ! -s "$OUT_WASM" ]; then
  echo "measure_fs_heap: no output wasm produced: $OUT_WASM" >&2
  exit 1
fi

awk -v mode="$MODE" -v wall="$((end_s - start_s))" '
  /^\[profile-memory\] / && / name=/ {
    heap = 0; pages = 0; bytes = 0; rss = 0; name = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^heap_ptr=/) { heap = substr($i, 10) + 0 }
      else if ($i ~ /^pages=/) { pages = substr($i, 7) + 0 }
      else if ($i ~ /^bytes=/) { bytes = substr($i, 7) + 0 }
      else if ($i ~ /^rss=/) { rss = substr($i, 5) + 0 }
      else if ($i ~ /^name=/) { name = substr($i, 6) }
    }
    printf "[fs-heap] mode=%s phase=%s heap_mib=%.1f delta_mib=%.1f pages=%d mem_mib=%.1f rss_mib=%.1f\n",
      mode, name, heap / 1048576, (heap - prev) / 1048576, pages, bytes / 1048576, rss / 1048576
    prev = heap
    if (heap > peak) { peak = heap; peak_pages = pages }
    seen = 1
  }
  END {
    if (!seen) {
      print "[fs-heap] ERROR: no named [profile-memory] marks in the log -- is the base compiler built from a tree that contains the #1553 marks?" > "/dev/stderr"
      exit 1
    }
    # wasm32 linear memory cap: 65536 pages = 4 GiB.
    printf "[fs-heap] mode=%s peak heap_mib=%.1f pages=%d headroom_mib=%.1f wall_s=%d\n",
      mode, peak / 1048576, peak_pages, (65536 - peak_pages) * 64 / 1024, wall
  }
' "$LOG"
