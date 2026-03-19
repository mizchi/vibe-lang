#!/usr/bin/env bash
# Benchmark `vibe normalize --write` on all .vibe source files.
# Reports per-directory and total wall-clock time.
# Usage:
#   scripts/bench_normalize.sh                      — default (debug build)
#   scripts/bench_normalize.sh --release            — release build
#   scripts/bench_normalize.sh --skip-unchanged     — use CLI skip-unchanged flag
# env:
#   VIBE_BENCH_NORMALIZE_RUNS  — number of iterations (default: 1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

RELEASE=0
EXTRA_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --skip-unchanged) EXTRA_FLAGS+=("--skip-unchanged") ;;
  esac
done

RUNS="${VIBE_BENCH_NORMALIZE_RUNS:-1}"

if [ "$RELEASE" = "1" ]; then
  VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
else
  source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
fi
VIBE_BIN="$VIBE_CLI_BIN"

SOURCE_ROOTS=(examples vibe)
EXCLUDE_DIRS="examples/wasm"

# Collect directories
DIRS=()
for root in "${SOURCE_ROOTS[@]}"; do
  while IFS= read -r d; do
    DIRS+=("$d")
  done < <(find "$root" -name '*.vibe' -type f -exec dirname {} \; | sort -u | grep -Ev "^($EXCLUDE_DIRS)$")
done

# Collect all files per directory
declare -A DIR_FILES
TOTAL_FILES=0
for dir in "${DIRS[@]}"; do
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -name '*.vibe' -type f | sort)
  [ ${#files[@]} -eq 0 ] && continue
  DIR_FILES["$dir"]="${files[*]}"
  TOTAL_FILES=$((TOTAL_FILES + ${#files[@]}))
done

echo "=== vibe normalize benchmark ==="
echo "files: $TOTAL_FILES"
echo "directories: ${#DIR_FILES[@]}"
echo "runs: $RUNS"
echo "build: $([ "$RELEASE" = "1" ] && echo "release" || echo "debug")"
if [ ${#EXTRA_FLAGS[@]} -gt 0 ]; then
  echo "flags: ${EXTRA_FLAGS[*]}"
fi
echo ""

# Run benchmark
best_total_ms=""
for run in $(seq 1 "$RUNS"); do
  if [ "$RUNS" -gt 1 ]; then
    echo "--- run $run/$RUNS ---"
  fi

  run_start=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
  for dir in "${!DIR_FILES[@]}"; do
    read -ra files <<< "${DIR_FILES[$dir]}"
    "$VIBE_BIN" normalize --write "${EXTRA_FLAGS[@]}" "${files[@]}" 2>/dev/null
  done
  run_end=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')

  run_ms=$(( (run_end - run_start) / 1000000 ))

  if [ -z "$best_total_ms" ] || [ "$run_ms" -lt "$best_total_ms" ]; then
    best_total_ms=$run_ms
  fi

  if [ "$RUNS" -gt 1 ]; then
    echo "  total: ${run_ms}ms"
  fi
done

echo ""
echo "=== results ==="
echo "total:    ${best_total_ms}ms (best of $RUNS)"
if [ "$TOTAL_FILES" -gt 0 ]; then
  avg_us=$(( best_total_ms * 1000 / TOTAL_FILES ))
  echo "per-file: ${avg_us}us (avg)"
fi
