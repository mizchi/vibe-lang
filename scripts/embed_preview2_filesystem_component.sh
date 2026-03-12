#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 <core.wasm> <world.wit> <out.component.wasm> [world-name]" >&2
  exit 1
fi

CORE_WASM="$1"
WORLD_WIT="$2"
OUT_COMPONENT="$3"
WORLD_NAME="${4:-}"

if [ ! -f "$CORE_WASM" ]; then
  echo "core wasm not found: $CORE_WASM" >&2
  exit 1
fi
if [ ! -f "$WORLD_WIT" ]; then
  echo "world wit not found: $WORLD_WIT" >&2
  exit 1
fi
if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -z "$WORLD_NAME" ]; then
  WORLD_NAME="$(awk '/^world / {print $2; exit}' "$WORLD_WIT")"
fi
if [ -z "$WORLD_NAME" ]; then
  echo "failed to detect world name from $WORLD_WIT" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "/tmp/vibe_preview2_fs_component.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WIT_DIR="$TMP_DIR/wit"
DEPS_DIR="$WIT_DIR/deps"
NORMALIZED_CORE_WASM="$TMP_DIR/core.normalized.wasm"
EMBEDDED_WASM="$TMP_DIR/embedded.wasm"

mkdir -p "$DEPS_DIR" "$(dirname "$OUT_COMPONENT")"
cp "$WORLD_WIT" "$WIT_DIR/world.wit"
cp \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/filesystem.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/io.wit" \
  "$PROJECT_ROOT/deps/wasmtime/crates/wasi/src/p2/wit/deps/clocks.wit" \
  "$DEPS_DIR/"

WORLD_WIT="$WIT_DIR/world.wit"
NORMALIZED_CORE_WASM="$NORMALIZED_CORE_WASM" WORLD_WIT="$WORLD_WIT" CORE_WASM="$CORE_WASM" python3 - <<'PY'
from pathlib import Path
import os

world_path = Path(os.environ["WORLD_WIT"])
world_text = world_path.read_text()
world_text = world_text.replace("wasi:filesystem/types@0.3.0", "wasi:filesystem/types@0.2.6")
world_text = world_text.replace("wasi:filesystem/preopens@0.3.0", "wasi:filesystem/preopens@0.2.6")
world_path.write_text(world_text)

core_in = Path(os.environ["CORE_WASM"]).read_bytes()
core_out = core_in.replace(
    b"wasi:filesystem/preopens@0.3.0",
    b"wasi:filesystem/preopens@0.2.6",
).replace(
    b"wasi:filesystem/types@0.3.0",
    b"wasi:filesystem/types@0.2.6",
)
Path(os.environ["NORMALIZED_CORE_WASM"]).write_bytes(core_out)
PY

wasm-tools component embed "$WIT_DIR" "$NORMALIZED_CORE_WASM" --world "$WORLD_NAME" -o "$EMBEDDED_WASM"
wasm-tools component new "$EMBEDDED_WASM" -o "$OUT_COMPONENT"
wasm-tools validate "$OUT_COMPONENT" >/dev/null

echo "wrote $OUT_COMPONENT"
