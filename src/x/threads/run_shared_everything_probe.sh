#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WAST_PATH="$SCRIPT_DIR/shared_everything_i31_probe.wast"

SIBLING_WASMTIME="$(cd "$PROJECT_ROOT/.." && pwd)/wasmtime/target/debug/wasmtime"
if [ -z "${WASMTIME_BIN:-}" ] && [ -x "$SIBLING_WASMTIME" ]; then
  export WASMTIME_BIN="$SIBLING_WASMTIME"
fi

if [ ! -f "$WAST_PATH" ]; then
  echo "probe wast not found: $WAST_PATH" >&2
  exit 1
fi

: "${VIBE_WASMTIME_WASM_FLAGS:=gc=y function-references=y shared-everything-threads=y}"
: "${VIBE_WASMTIME_WASI_FLAGS:=}"

WASMTIME_RESOLVED="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh")"

echo "WAST: $WAST_PATH"
echo "wasmtime: $("$WASMTIME_RESOLVED" --version)"
echo "VIBE_WASMTIME_WASM_FLAGS=$VIBE_WASMTIME_WASM_FLAGS"
echo "VIBE_WASMTIME_WASI_FLAGS=$VIBE_WASMTIME_WASI_FLAGS"

VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$WAST_PATH"
