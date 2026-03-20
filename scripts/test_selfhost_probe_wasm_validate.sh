#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FIXTURE_PATH="${1:-$PROJECT_ROOT/vibe/selfhost_probe_types_run.vibe}"
OUT_WASM="${2:-/tmp/selfhost_probe_types_run.wasm}"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe}"

if [ ! -f "$FIXTURE_PATH" ]; then
  echo "fixture not found: $FIXTURE_PATH" >&2
  exit 1
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required" >&2
  exit 1
fi

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native src/cmd/vibe --warn-list '-29' >/dev/null
  VIBE_BIN="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"
fi

mkdir -p "$(dirname "$OUT_WASM")"

"$VIBE_BIN" compile --wasm "$FIXTURE_PATH" -o "$OUT_WASM"
wasm-tools validate --features all "$OUT_WASM"

echo "validated: $OUT_WASM"
