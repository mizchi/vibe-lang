#!/usr/bin/env bash
set -euo pipefail

# Compose a vibe HTTP handler into a ready-to-serve WASI P3 component.
#
# Usage: compose_http_p3_handler.sh <input.vibe> [-o output.wasm]
#
# The vibe source must export a handler function:
#   export let handler = (method: String, url: String) -> Int { ... }
#
# Protocol:
#   handler returns >= 0 → direct HTTP response with that status code
#   handler returns -1   → proxy GET to URL from ?target= query param
#   handler returns -2   → proxy POST to URL from ?target= query param
#
# Output: a WASI P3 component that can be served with:
#   wasmtime serve -Sp3 -W component-model-async=y -W component-model-async-stackful=y -W exceptions=y -W concurrency-support=y output.wasm

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${VIBE_HTTP_P3_CACHE:-$PROJECT_ROOT/_build/http_adapter}"
VIBE="${VIBE:-moon run --target native src/cmd/vibe --}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd moon
require_cmd wasm-tools

INPUT=""
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTPUT="$2"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) INPUT="$1"; shift ;;
  esac
done

if [ -z "$INPUT" ]; then
  echo "usage: compose_http_p3_handler.sh <input.vibe> [-o output.wasm]" >&2
  exit 1
fi

if [ -z "$OUTPUT" ]; then
  OUTPUT="${INPUT%.vibe}.component.wasm"
fi

mkdir -p "$CACHE_DIR"

# Step 1: Build combined adapter (cached)
ADAPTER="$CACHE_DIR/vibe_http_p3_combined_adapter.component.wasm"
if [ ! -f "$ADAPTER" ]; then
  echo "[compose] building combined adapter (first time)..."
  "$SCRIPT_DIR/build_wasi_http_p3_combined_adapter.sh" "$ADAPTER" 2>&1 | tail -1
else
  echo "[compose] using cached adapter"
fi

# Step 2: Compile + compose + patch via vibe CLI
echo "[compose] compiling and composing $INPUT..."
$VIBE compile --compose-p3 --adapter "$ADAPTER" "$INPUT" -o "$OUTPUT"

# Step 3: Validate
wasm-tools validate --features all "$OUTPUT"
echo "[compose] wrote $OUTPUT"
echo "[compose] serve with: wasmtime serve -Sp3 -W component-model-async=y -W component-model-async-stackful=y -W exceptions=y -W concurrency-support=y $OUTPUT"
