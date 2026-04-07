#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_command_parity}"
COMPONENT_PATH="$OUT_DIR/selfhost_cli_preview2.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_cli_preview2.component.wit"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"

mkdir -p "$OUT_DIR"

if [ ! -x "$VIBE_BIN" ]; then
  echo "[selfhost-cli-command-parity] building host CLI..." >&2
  moon build --target native src/cmd/vibe --warn-list '-29'
fi

bash "$SCRIPT_DIR/build_selfhost_cli_preview2_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

run_case() {
  local case_name="$1"
  local entry_name="$2"
  local source_text="$3"
  local expected_result="$4"
  local mode="$5"
  local case_dir="$OUT_DIR/$case_name"
  local input_path="$case_dir/input.vibe"
  local host_out="$case_dir/host.wasm"
  local selfhost_out="$case_dir/selfhost.wasm"
  local host_run_log="$case_dir/host.run.log"
  local selfhost_run_log="$case_dir/selfhost.run.log"

  mkdir -p "$case_dir"
  printf '%s' "$source_text" >"$input_path"
  rm -f "$host_out" "$selfhost_out" "$host_run_log" "$selfhost_run_log"

  if [ "$mode" = "no-dce" ]; then
    "$VIBE_BIN" compile-lite --wasm-linear --no-dce "$input_path" -o "$host_out"
  else
    "$VIBE_BIN" compile-lite --wasm-linear "$input_path" -o "$host_out"
  fi
  bash "$SCRIPT_DIR/run_selfhost_cli_preview2_component.sh" \
    "$COMPONENT_PATH" \
    "$input_path" \
    "$selfhost_out" \
    "$entry_name" \
    "$mode"

  wasm-tools validate "$host_out" >/dev/null
  wasm-tools validate "$selfhost_out" >/dev/null

  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    "$WASMTIME_RUN" --invoke _start "$host_out" >"$host_run_log"
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    "$WASMTIME_RUN" --invoke _start "$selfhost_out" >"$selfhost_run_log"

  local host_result
  local selfhost_result
  host_result="$(grep -E '^-?[0-9]+$' "$host_run_log" | tail -n 1 || true)"
  selfhost_result="$(grep -E '^-?[0-9]+$' "$selfhost_run_log" | tail -n 1 || true)"
  if [ -z "$host_result" ]; then
    echo "selfhost cli command parity gate failed: host result missing for $case_name" >&2
    exit 1
  fi
  if [ "$selfhost_result" != "$expected_result" ]; then
    echo "selfhost cli command parity gate failed: selfhost result mismatch for $case_name: $selfhost_result" >&2
    exit 1
  fi
}

run_case \
  "answer_no_dce" \
  "answer" \
  $'let answer = () -> Int { 40 + 2 }\n' \
  "42" \
  "no-dce"

echo "selfhost cli command parity gate passed"
