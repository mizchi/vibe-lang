#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_cli_adapter"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_fixed_adapter.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_CLI_FIXED_ADAPTER_STAGE_TIMEOUT_SEC:-300}"
DRIVER_COMPONENT="$OUT_DIR/fixed_adapter_driver.component.wasm"
INPUT_SOURCE="$OUT_DIR/fixed_adapter_input.vibe"
OUTPUT_WASM="$OUT_DIR/fixed_adapter_output.wasm"
OUTPUT_RUN_LOG="$OUT_DIR/fixed_adapter_output_run.log"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"

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
  echo "[selfhost-cli-preview2] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli-preview2] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  echo "[selfhost-cli-preview2] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli-preview2] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

mkdir -p "$OUT_DIR"
rm -f "$DRIVER_COMPONENT" "$OUTPUT_WASM" "$OUTPUT_RUN_LOG"

cat >"$INPUT_SOURCE" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

run_stage "host compiler -> fixed selfhost cli preview2 driver component" \
  bash "$PROJECT_ROOT/scripts/component_wkg_stdio.sh" "$ENTRY_PATH" "$DRIVER_COMPONENT"

run_stage "run fixed selfhost cli driver component via wasmtime preview2 fs" \
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    "$WASMTIME_RUN" --dir . --invoke 'run()' "$DRIVER_COMPONENT"

if [ ! -f "$OUTPUT_WASM" ]; then
  echo "selfhost fixed adapter preview2 gate failed: sample wasm not produced" >&2
  exit 1
fi

output_magic="$(od -An -t x1 -N 4 "$OUTPUT_WASM" | tr -d ' \n')"
if [ "$output_magic" != "0061736d" ]; then
  echo "selfhost fixed adapter preview2 gate failed: sample artifact is not wasm (magic=$output_magic)" >&2
  exit 1
fi

run_stage_capture_stdout "run sample wasm produced by fixed preview2 adapter" \
  "$OUTPUT_RUN_LOG" \
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    "$WASMTIME_RUN" --invoke _start "$OUTPUT_WASM"

sample_tagged="$(grep -E '^-?[0-9]+$' "$OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$sample_tagged" ]; then
  echo "selfhost fixed adapter preview2 gate failed: compiled sample returned no numeric result" >&2
  exit 1
fi

if [ "$sample_tagged" != "42" ]; then
  echo "selfhost fixed adapter preview2 gate failed: compiled sample returned '$sample_tagged' (expected 42)" >&2
  exit 1
fi

echo "selfhost fixed adapter preview2 gate passed"
