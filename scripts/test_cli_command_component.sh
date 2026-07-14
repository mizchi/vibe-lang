#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_command_component}"
COMPONENT_PATH="$OUT_DIR/selfhost_cli_command.component.wasm"
WIT_PATH="$OUT_DIR/selfhost_cli_command.component.wit"
INPUT_SOURCE="$OUT_DIR/input.vibe"
OUTPUT_WASM="$OUT_DIR/output.wasm"
OUTPUT_RUN_LOG="$OUT_DIR/output.run.log"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-cli=y}"
DEBUG_FLAG="${VIBE_CLI_COMMAND_DEBUG:-0}"
ENTRY_NAME="${ENTRY_NAME:-answer}"

mkdir -p "$OUT_DIR"
rm -f "$COMPONENT_PATH" "$WIT_PATH" "$OUTPUT_WASM" "$OUTPUT_RUN_LOG"

cat >"$INPUT_SOURCE" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

bash "$PROJECT_ROOT/scripts/build_selfhost_cli_command_component.sh" "$COMPONENT_PATH" "$WIT_PATH"

if ! grep -q 'export wasi:cli/run@0.2.6;' "$WIT_PATH"; then
  echo "selfhost cli command component gate failed: component wit is not command-shaped" >&2
  exit 1
fi

(
  cd "$OUT_DIR"
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    VIBE_CLI_COMMAND_DEBUG="$DEBUG_FLAG" \
    "$WASMTIME_RUN" run --dir . "$COMPONENT_PATH" "$ENTRY_NAME" <"$INPUT_SOURCE" >"$OUTPUT_WASM"
)

output_magic="$(od -An -t x1 -N 4 "$OUTPUT_WASM" | tr -d ' \n')"
if [ "$output_magic" != "0061736d" ]; then
  echo "selfhost cli command component gate failed: compiled output is not wasm (magic=$output_magic)" >&2
  exit 1
fi

wasm-tools validate "$OUTPUT_WASM" >/dev/null

env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
  VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
  "$WASMTIME_RUN" --invoke _start "$OUTPUT_WASM" >"$OUTPUT_RUN_LOG"

sample_result="$(grep -E '^-?[0-9]+$' "$OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$sample_result" ]; then
  echo "selfhost cli command component gate failed: sample returned no numeric result" >&2
  exit 1
fi

if [ "$sample_result" != "42" ]; then
  echo "selfhost cli command component gate failed: sample returned '$sample_result' (expected 42)" >&2
  exit 1
fi

echo "selfhost cli command component gate passed"
