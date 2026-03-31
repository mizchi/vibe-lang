#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 <component.wasm> <input.vibe> <output.wasm> <entry> [mode]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
COMPONENT_PATH="$1"
INPUT_PATH="$2"
OUTPUT_PATH="$3"
ENTRY_NAME="$4"
COMPILE_MODE="${5:-mvp}"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-}"
COMPONENT_EXPORT_NAME="${VIBE_SELFHOST_CLI_COMPONENT_EXPORT_NAME:-compile-cli-request}"

if [ ! -f "$COMPONENT_PATH" ]; then
  echo "component not found: $COMPONENT_PATH" >&2
  exit 1
fi
if [ ! -f "$INPUT_PATH" ]; then
  echo "input not found: $INPUT_PATH" >&2
  exit 1
fi

quote_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

SOURCE_EXPR="$(python3 -c 'import json, pathlib, sys; print(json.dumps(pathlib.Path(sys.argv[1]).read_text()))' "$INPUT_PATH")"

invoke_component_request() {
  local request="$1"
  local request_expr raw
  request_expr="$(quote_string "$request")"
  raw="$(
    env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
      VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
      "$WASMTIME_RUN" \
      --invoke "$COMPONENT_EXPORT_NAME($SOURCE_EXPR,$request_expr)" \
      "$COMPONENT_PATH" | grep -E '^-?[0-9]+$' | tail -n 1 || true
  )"
  if [ -z "$raw" ]; then
    echo "component returned no numeric result for request '$request'" >&2
    return 1
  fi
  echo $((raw / 4))
}

mkdir -p "$(dirname "$OUTPUT_PATH")"
: >"$OUTPUT_PATH"

component_len="$(invoke_component_request "len-mode:$COMPILE_MODE:$ENTRY_NAME")"
if [ "$component_len" -le 8 ]; then
  echo "component returned too small wasm length: $component_len" >&2
  exit 1
fi

chunk_count=$(((component_len + 6) / 7))
remaining="$component_len"
for ((chunk_index = 0; chunk_index < chunk_count; chunk_index++)); do
  packed="$(invoke_component_request "chunk-mode:$COMPILE_MODE:$ENTRY_NAME:$chunk_index")"
  python3 - "$packed" "$remaining" "$OUTPUT_PATH" <<'PY'
import pathlib
import sys

packed = int(sys.argv[1])
remaining = int(sys.argv[2])
path = pathlib.Path(sys.argv[3])
count = 7 if remaining >= 7 else remaining
data = bytes((packed >> (8 * i)) & 0xFF for i in range(count))
with path.open("ab") as fh:
    fh.write(data)
PY
  remaining=$((remaining - 7))
done
