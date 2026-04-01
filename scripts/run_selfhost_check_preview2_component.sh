#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <component.wasm> <input.vibe>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
COMPONENT_PATH="$1"
INPUT_PATH="$2"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"
WASMTIME_WASI_FLAGS="${VIBE_WASMTIME_WASI_FLAGS:-}"
COMPONENT_EXPORT_NAME="${VIBE_SELFHOST_CHECK_COMPONENT_EXPORT_NAME:-check-source-report}"

if [ ! -f "$COMPONENT_PATH" ]; then
  echo "component not found: $COMPONENT_PATH" >&2
  exit 1
fi
if [ ! -f "$INPUT_PATH" ]; then
  echo "input not found: $INPUT_PATH" >&2
  exit 1
fi

SOURCE_EXPR="$(python3 -c 'import json, pathlib, sys; print(json.dumps(pathlib.Path(sys.argv[1]).read_text()))' "$INPUT_PATH")"

RAW_OUTPUT="$(
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
    VIBE_WASMTIME_WASI_FLAGS="$WASMTIME_WASI_FLAGS" \
    "$WASMTIME_RUN" \
    --invoke "$COMPONENT_EXPORT_NAME($SOURCE_EXPR)" \
    "$COMPONENT_PATH"
)"

printf '%s\n' "$RAW_OUTPUT" | python3 -c '
import json, sys
lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
if not lines:
    raise SystemExit("component returned no output")
print(json.loads(lines[-1]))
'
