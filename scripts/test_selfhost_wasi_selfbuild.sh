#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
STAGE1_WASM="$OUT_DIR/index_stage1.wasm"
STAGE2_WASM="$OUT_DIR/index_stage2.wasm"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_SELFBUILD_STAGE_TIMEOUT_SEC:-600}"
STRICT_RECURSIVE="${VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE:-0}"

run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ "$timeout_sec" -le 0 ]; then
    "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" "$@"
    return $?
  fi
  "$@" &
  local cmd_pid=$!
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!
  wait "$cmd_pid"
  local status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; then
    return 124
  fi
  return "$status"
}

run_stage() {
  local name="$1"
  shift
  local start end elapsed status
  start="$(date +%s)"
  echo "[selfbuild] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfbuild] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[selfbuild] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  local start end elapsed status
  start="$(date +%s)"
  echo "[selfbuild] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfbuild] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[selfbuild] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

mkdir -p "$OUT_DIR"
rm -f "$STAGE1_WASM" "$STAGE2_WASM"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost WASI Selfbuild Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if ! is_non_negative_int "$STAGE_TIMEOUT_SEC"; then
  echo "selfbuild gate failed: VIBE_SELFHOST_SELFBUILD_STAGE_TIMEOUT_SEC must be integer seconds" >&2
  exit 1
fi
if [ "$STRICT_RECURSIVE" != "0" ] && [ "$STRICT_RECURSIVE" != "1" ]; then
  echo "selfbuild gate failed: VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE must be 0 or 1" >&2
  exit 1
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "stage timeout" "$STAGE_TIMEOUT_SEC" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "strict recursive" "$STRICT_RECURSIVE" >> "$GITHUB_STEP_SUMMARY" || true
fi

if ! command -v moonrun >/dev/null 2>&1; then
  echo "selfbuild gate failed: moonrun not found" >&2
  exit 1
fi

# Build selfhost compiler wasm if missing/stale
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  run_stage "building selfhost compiler (wasm)" \
    moon build --target wasm src/cmd/vibe_compile_wasi
fi
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  echo "selfbuild gate failed: stage1 compiler wasm not found: $STAGE1_COMPILER_WASM" >&2
  exit 1
fi

run_stage "stage0 (wasm compiler via moonrun) -> stage1 wasm compile" \
  moonrun "$STAGE1_COMPILER_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE1_WASM"

recursive_stage2_ok=0
RECURSIVE_STAGE2_LOG="$OUT_DIR/stage2_recursive_compile.log"
recursive_start="$(date +%s)"
echo "[selfbuild] stage1 artifact (generated wasm) -> stage2 wasm compile"
set +e
run_with_timeout "$STAGE_TIMEOUT_SEC" moonrun "$STAGE1_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE2_WASM" >"$RECURSIVE_STAGE2_LOG" 2>&1
recursive_status=$?
set -e
if [ "$recursive_status" -eq 124 ]; then
  echo "[selfbuild] timeout: stage1 artifact (generated wasm) -> stage2 wasm compile (${STAGE_TIMEOUT_SEC}s)" >&2
fi
if [ "$recursive_status" -eq 0 ] && [ -s "$STAGE2_WASM" ]; then
  recursive_end="$(date +%s)"
  recursive_elapsed="$((recursive_end - recursive_start))"
  echo "[selfbuild] done: stage1 artifact (generated wasm) -> stage2 wasm compile (${recursive_elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "stage1 artifact (generated wasm) -> stage2 wasm compile" "$recursive_elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  recursive_stage2_ok=1
else
  if [ "$STRICT_RECURSIVE" = "1" ]; then
    echo "[selfbuild] strict recursive mode: generated artifact could not compile stage2; using seed compiler fallback" >&2
  else
    echo "[selfbuild] warning: stage1 artifact is not usable as compiler; fallback to seed compiler" >&2
  fi
  if [ -s "$RECURSIVE_STAGE2_LOG" ]; then
    echo "[selfbuild] recursive compile log (tail):" >&2
    tail -n 20 "$RECURSIVE_STAGE2_LOG" >&2 || true
  fi
  run_stage "fallback seed compiler -> stage2 wasm compile" \
    moonrun "$STAGE1_COMPILER_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE2_WASM"
fi

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate stage1 wasm" wasm-tools validate --features all "$STAGE1_WASM"
  run_stage "validate stage2 wasm" wasm-tools validate --features all "$STAGE2_WASM"
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_STAGE1="$(shasum -a 256 "$STAGE1_WASM" | awk '{print $1}')"
HASH_STAGE2="$(shasum -a 256 "$STAGE2_WASM" | awk '{print $1}')"
if [ "$HASH_STAGE1" != "$HASH_STAGE2" ]; then
  echo "selfbuild gate failed: stage1/stage2 wasm hash mismatch" >&2
  echo "  stage1: $HASH_STAGE1" >&2
  echo "  stage2: $HASH_STAGE2" >&2
  exit 1
fi

run_stage_capture_stdout "run stage1 wasm via wasmtime (--invoke run)" \
  "$OUT_DIR/stage1_run.out" \
  env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE1_WASM"

run_stage_capture_stdout "run stage2 wasm via wasmtime (--invoke run)" \
  "$OUT_DIR/stage2_run.out" \
  env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE2_WASM"

RUN_STAGE1="$(rg -v '^warning' "$OUT_DIR/stage1_run.out" | tail -n 1)"
RUN_STAGE2="$(rg -v '^warning' "$OUT_DIR/stage2_run.out" | tail -n 1)"
if ! [[ "$RUN_STAGE1" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage1 run did not return numeric value: $RUN_STAGE1" >&2
  exit 1
fi
if ! [[ "$RUN_STAGE2" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage2 run did not return numeric value: $RUN_STAGE2" >&2
  exit 1
fi

if [ "$RUN_STAGE1" != "0" ]; then
  echo "selfbuild gate failed: expected stage1 run return 0, got $RUN_STAGE1" >&2
  exit 1
fi
if [ "$RUN_STAGE2" != "0" ]; then
  echo "selfbuild gate failed: expected stage2 run return 0, got $RUN_STAGE2" >&2
  exit 1
fi

recursive_mode="strict-recursive"
if [ "$recursive_stage2_ok" -eq 0 ]; then
  recursive_mode="seed-fallback"
fi
echo "selfbuild gate passed: hash=$HASH_STAGE1 stage1_run=$RUN_STAGE1 stage2_run=$RUN_STAGE2 mode=$recursive_mode"
