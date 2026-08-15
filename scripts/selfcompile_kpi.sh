#!/usr/bin/env bash
# Self-compile KPI: wall time + bump-heap high-water of ONE real compile
# through a selfhost stage2 artifact, as a single parseable line.
#
# Complements scripts/profile_compile.sh (hotspot table, cpuprofile): this
# script is the cheap always-on number you can track per commit or gate in CI.
#
#   scripts/selfcompile_kpi.sh <stage2.wasm> [input.vibe]
#
# Output (stdout, last line):
#   [selfcompile-kpi] input=<path> wall_ms=<n> heap_ptr_bytes=<n> mem_pages=<n>
#
# Gate (opt-in): heap_ptr is the linear backend's bump-allocator high-water —
# single-threaded and byte-deterministic for a fixed (stage2, input) pair, so
# unlike wall time it can gate CI without flakes. Thresholds only make sense
# against a stage2 built from the same commit; re-baseline when the compiler
# changes.
#   VIBE_KPI_MAX_HEAP_BYTES=<n>  exit 1 if heap_ptr_bytes exceeds this
#   VIBE_KPI_MAX_WALL_MS=<n>     exit 1 if wall_ms exceeds this (advisory —
#                                wall time IS machine/load dependent; prefer
#                                the heap gate for CI)
#   VIBE_KPI_WORK_DIR=<path>      use one fixed empty directory under
#                                VIBE_KPI_ALLOWED_WORK_ROOT (default: _build)
#                                instead of mktemp; the directory is removed
#                                on exit. This is used by comparative policy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

STAGE2="${1:-}"
INPUT="${2:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
if [ -z "$STAGE2" ] || [ ! -f "$STAGE2" ]; then
  echo "usage: scripts/selfcompile_kpi.sh <stage2.wasm> [input.vibe]" >&2
  exit 2
fi
if [ ! -f "$INPUT" ]; then
  echo "[selfcompile-kpi] input not found: $INPUT" >&2
  exit 2
fi

cleanup_out_dir() {
  if [ -n "${OUT_DIR:-}" ]; then
    rm -rf -- "$OUT_DIR"
  fi
}

if [ -n "${VIBE_KPI_WORK_DIR:-}" ]; then
  case "$VIBE_KPI_WORK_DIR" in
    /*) ;;
    *)
      echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must be absolute" >&2
      exit 2
      ;;
  esac
  if [ -L "$VIBE_KPI_WORK_DIR" ]; then
    echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must not be a symlink" >&2
    exit 2
  fi
  if [ -e "$VIBE_KPI_WORK_DIR" ] && [ ! -d "$VIBE_KPI_WORK_DIR" ]; then
    echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must be a directory" >&2
    exit 2
  fi
  if [ -d "$VIBE_KPI_WORK_DIR" ] && [ -n "$(find "$VIBE_KPI_WORK_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must be empty" >&2
    exit 2
  fi

  ALLOWED_WORK_ROOT="${VIBE_KPI_ALLOWED_WORK_ROOT:-$ROOT_DIR/_build}"
  case "$ALLOWED_WORK_ROOT" in
    /*) ;;
    *)
      echo "[selfcompile-kpi] VIBE_KPI_ALLOWED_WORK_ROOT must be absolute" >&2
      exit 2
      ;;
  esac
  mkdir -p -- "$ALLOWED_WORK_ROOT"
  ALLOWED_WORK_ROOT_REAL="$(cd "$ALLOWED_WORK_ROOT" && pwd -P)"
  WORK_PARENT="$(dirname "$VIBE_KPI_WORK_DIR")"
  case "$WORK_PARENT/" in
    "$ALLOWED_WORK_ROOT"/|"$ALLOWED_WORK_ROOT"/*/) ;;
    *)
      echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must be under $ALLOWED_WORK_ROOT_REAL" >&2
      exit 2
      ;;
  esac
  mkdir -p -- "$WORK_PARENT"
  WORK_PARENT_REAL="$(cd "$WORK_PARENT" && pwd -P)"
  WORK_PARENT_SUFFIX="${WORK_PARENT#"$ALLOWED_WORK_ROOT"}"
  WORK_PARENT_SUFFIX="${WORK_PARENT_SUFFIX#/}"
  EXPECTED_WORK_PARENT_REAL="$ALLOWED_WORK_ROOT_REAL"
  if [ -n "$WORK_PARENT_SUFFIX" ]; then
    EXPECTED_WORK_PARENT_REAL="$EXPECTED_WORK_PARENT_REAL/$WORK_PARENT_SUFFIX"
  fi
  if [ "$WORK_PARENT_REAL" != "$EXPECTED_WORK_PARENT_REAL" ]; then
    echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must not contain symlinked directories" >&2
    exit 2
  fi
  case "$WORK_PARENT_REAL/" in
    "$ALLOWED_WORK_ROOT_REAL"/|"$ALLOWED_WORK_ROOT_REAL"/*/) ;;
    *)
      echo "[selfcompile-kpi] VIBE_KPI_WORK_DIR must be under $ALLOWED_WORK_ROOT_REAL" >&2
      exit 2
      ;;
  esac
  case "$VIBE_KPI_WORK_DIR" in
    /|"$ROOT_DIR"|"$ALLOWED_WORK_ROOT_REAL")
      echo "[selfcompile-kpi] unsafe VIBE_KPI_WORK_DIR: $VIBE_KPI_WORK_DIR" >&2
      exit 2
      ;;
  esac
  OUT_DIR="$VIBE_KPI_WORK_DIR"
  [ -d "$OUT_DIR" ] || mkdir -- "$OUT_DIR"
else
  OUT_DIR="$(mktemp -d)"
fi
trap cleanup_out_dir EXIT
OUT_WASM="$OUT_DIR/out.wasm"
STATS_FILE="$OUT_DIR/stats.txt"

# Cold, isolated build cache (#849 VIBE_BUILD_CACHE_DIR): with the shared
# persistent cache the second run compiles less and allocates ~half the
# bytes, so heap_ptr would measure cache state instead of the compiler.
CACHE_DIR="$OUT_DIR/cache"
mkdir -p "$CACHE_DIR"

start_ns=$(date +%s%N)
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_WASM_MEMORY_STATS=1 VIBE_BUILD_CACHE_DIR="$CACHE_DIR" \
  bash "${VIBE_KPI_RUNNER_SCRIPT:-scripts/run_wasm_vibe_host_runner.sh}" --invoke cli_main "$STAGE2" \
  "$INPUT" "$OUT_WASM" __no_entry__ 2>"$STATS_FILE"
end_ns=$(date +%s%N)
wall_ms=$(( (end_ns - start_ns) / 1000000 ))

if [ ! -s "$OUT_WASM" ]; then
  echo "[selfcompile-kpi] compile produced no output wasm (REJECT?):" >&2
  tail -5 "$STATS_FILE" >&2 || true
  [ -f "$OUT_WASM.diag" ] && tail -5 "$OUT_WASM.diag" >&2
  exit 1
fi

# last [wasm-memory] line is the end-of-run high-water
mem_line=$(grep '\[wasm-memory\]' "$STATS_FILE" | tail -1 || true)
heap_bytes=$(sed -n 's/.*heap_ptr=\([0-9][0-9]*\).*/\1/p' <<<"$mem_line")
mem_pages=$(sed -n 's/.*pages=\([0-9][0-9]*\).*/\1/p' <<<"$mem_line")
if [ -z "$heap_bytes" ]; then
  echo "[selfcompile-kpi] no [wasm-memory] heap_ptr in runner stderr — runner regression?" >&2
  tail -5 "$STATS_FILE" >&2 || true
  exit 1
fi

echo "[selfcompile-kpi] input=$INPUT wall_ms=$wall_ms heap_ptr_bytes=$heap_bytes mem_pages=${mem_pages:-?}"

rc=0
if [ -n "${VIBE_KPI_MAX_HEAP_BYTES:-}" ] && [ "$heap_bytes" -gt "$VIBE_KPI_MAX_HEAP_BYTES" ]; then
  echo "[selfcompile-kpi] GATE FAIL: heap_ptr_bytes $heap_bytes > VIBE_KPI_MAX_HEAP_BYTES $VIBE_KPI_MAX_HEAP_BYTES" >&2
  rc=1
fi
if [ -n "${VIBE_KPI_MAX_WALL_MS:-}" ] && [ "$wall_ms" -gt "$VIBE_KPI_MAX_WALL_MS" ]; then
  echo "[selfcompile-kpi] GATE FAIL: wall_ms $wall_ms > VIBE_KPI_MAX_WALL_MS $VIBE_KPI_MAX_WALL_MS" >&2
  rc=1
fi
exit $rc
