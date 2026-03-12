#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <component.wasm> <input.vibe> <output.wasm> <entry>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENT_PATH="$1"
INPUT_PATH="$2"
OUTPUT_PATH="$3"
ENTRY_NAME="$4"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-cli=y}"

if [ ! -f "$COMPONENT_PATH" ]; then
  echo "component not found: $COMPONENT_PATH" >&2
  exit 1
fi
if [ ! -f "$INPUT_PATH" ]; then
  echo "input not found: $INPUT_PATH" >&2
  exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT_PATH")" && pwd)"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
if [ "$INPUT_DIR" != "$OUTPUT_DIR" ]; then
  echo "input/output must be in the same directory for now" >&2
  exit 1
fi

INPUT_NAME="$(basename "$INPUT_PATH")"
OUTPUT_NAME="$(basename "$OUTPUT_PATH")"

quote_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

INPUT_EXPR="$(quote_string "$INPUT_NAME")"
OUTPUT_EXPR="$(quote_string "$OUTPUT_NAME")"
ENTRY_EXPR="$(quote_string "$ENTRY_NAME")"

(
  cd "$INPUT_DIR"
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    "$WASMTIME_RUN" \
    run \
    --dir . \
    --invoke "run-cli-request($INPUT_EXPR,$OUTPUT_EXPR,$ENTRY_EXPR)" \
    "$COMPONENT_PATH"
)
