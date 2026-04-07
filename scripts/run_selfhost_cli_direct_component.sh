#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 <component.wasm> <input.vibe> <output.wasm> <entry> [mode]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPONENT_PATH="$1"
INPUT_PATH="$2"
OUTPUT_PATH="$3"
ENTRY_NAME="$4"
COMPILE_MODE="${5:-mvp}"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"
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
TMP_DIR="$(mktemp -d /tmp/vibe_selfhost_cli_direct_run.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

INPUT_NAME="$(basename "$INPUT_PATH")"
PAYLOAD_NAME="input.payload"
OUTPUT_NAME="output.wasm"
cp -R "$INPUT_DIR"/. "$TMP_DIR/"

ensure_host_vibe_bin() {
  if [ ! -x "$VIBE_BIN" ]; then
    moon build --target native --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
    return
  fi
  if ! "$VIBE_BIN" 2>&1 | grep -q 'emit-closure-payload'; then
    moon build --target native --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
  fi
}

ensure_host_vibe_bin

quote_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

INPUT_EXPR="$(quote_string "$PAYLOAD_NAME")"
OUTPUT_EXPR="$(quote_string "$OUTPUT_NAME")"
ENTRY_EXPR="$(quote_string "$ENTRY_NAME")"
MODE_EXPR="$(quote_string "$COMPILE_MODE")"

STAGED_INPUT_PATH="$TMP_DIR/$INPUT_NAME"
STAGED_PAYLOAD_PATH="$TMP_DIR/$PAYLOAD_NAME"
"$VIBE_BIN" emit-closure-payload "$STAGED_INPUT_PATH" "$STAGED_PAYLOAD_PATH"

(
  cd "$TMP_DIR"
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    "$WASMTIME_RUN" \
    run \
    --dir . \
    --invoke "run-cli-request($INPUT_EXPR,$OUTPUT_EXPR,$ENTRY_EXPR,$MODE_EXPR)" \
    "$COMPONENT_PATH"
)

cp "$TMP_DIR/$OUTPUT_NAME" "$OUTPUT_PATH"
