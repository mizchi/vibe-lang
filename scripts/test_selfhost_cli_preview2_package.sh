#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_preview2_package}"
COMPONENT_PATH="$OUT_DIR/selfhost_cli_preview2.component.wasm"
COMPONENT_WIT="$OUT_DIR/selfhost_cli_preview2.component.wit"
INPUT_PATH="$OUT_DIR/input.vibe"
OUTPUT_PATH="$OUT_DIR/output.wasm"
RUN_LOG="$OUT_DIR/output.run.log"

mkdir -p "$OUT_DIR"
printf 'let answer = () -> Int { 40 + 2 }\n' >"$INPUT_PATH"

bash "$SCRIPT_DIR/build_selfhost_cli_preview2_component.sh" "$COMPONENT_PATH" "$COMPONENT_WIT"
bash "$SCRIPT_DIR/run_selfhost_cli_preview2_component.sh" "$COMPONENT_PATH" "$INPUT_PATH" "$OUTPUT_PATH" answer

wasm-tools validate "$OUTPUT_PATH" >/dev/null
env VIBE_WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y,threads=y}" \
  "$SCRIPT_DIR/wasmtime_run.sh" --invoke _start "$OUTPUT_PATH" >"$RUN_LOG"

RESULT="$(grep -E '^-?[0-9]+$' "$RUN_LOG" | tail -n 1 || true)"
if [ "$RESULT" != "42" ]; then
  echo "selfhost cli preview2 package gate failed: compiled sample returned '$RESULT' (expected 42)" >&2
  exit 1
fi

echo "selfhost cli preview2 package gate passed"
