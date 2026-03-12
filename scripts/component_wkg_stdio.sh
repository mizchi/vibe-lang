#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <input.vibe> [output.component.wasm]" >&2
  exit 1
fi

INPUT="$1"
if [ ! -f "$INPUT" ]; then
  echo "input not found: $INPUT" >&2
  exit 1
fi

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

BASE="$(basename "$INPUT")"
BASE="${BASE%.*}"
OUT="${2:-dist/${BASE}.component.wasm}"
mkdir -p "$(dirname "$OUT")"

TMP_DIR="$(mktemp -d "/tmp/vibe_component_wkg_${BASE}.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CORE_WASM="${TMP_DIR}/${BASE}.wasm"
WIT_DIR="${TMP_DIR}/wit"
mkdir -p "$WIT_DIR"
WIT_WORLD="${WIT_DIR}/world.wit"
EMBEDDED_WASM="${TMP_DIR}/${BASE}.embedded.wasm"
WIT_PKG="${TMP_DIR}/${BASE}.wit.wasm"

RELEASE_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
if [ -x "$RELEASE_VIBE_EXE" ]; then
  VIBE_CMD=("$RELEASE_VIBE_EXE" compile)
else
  VIBE_CMD=(moon run --target native src/cmd/vibe -- compile)
fi

"${VIBE_CMD[@]}" --wasm --force-cabi-realloc "$INPUT" -o "$CORE_WASM"
"${VIBE_CMD[@]}" --wit-component "$INPUT" -o "$WIT_WORLD"
WORLD_NAME="$(awk '/^world / {print $2; exit}' "$WIT_WORLD")"
if [ -z "$WORLD_NAME" ]; then
  echo "failed to detect world name from $WIT_WORLD" >&2
  exit 1
fi

if grep -q '^  import vibe: interface {$' "$WIT_WORLD"; then
  "${VIBE_CMD[@]}" --component "$INPUT" -o "$OUT"
  wasm-tools validate "$OUT" >/dev/null
  echo "wrote $OUT"
  exit 0
fi

if grep -Eq 'wasi:filesystem/types@0\.(2\.6|3\.0)' "$WIT_WORLD"; then
  "$SCRIPT_DIR/embed_preview2_filesystem_component.sh" "$CORE_WASM" "$WIT_WORLD" "$OUT" "$WORLD_NAME"
  exit 0
fi

if ! command -v wkg >/dev/null 2>&1; then
  echo "wkg is required for non-filesystem Preview2 component embedding" >&2
  exit 1
fi

# Resolve and lock WIT dependencies via wkg (also validates package shape).
(
  cd "$TMP_DIR"
  wkg wit fetch -d "$WIT_DIR" >/dev/null
  wkg wit build -d "$WIT_DIR" -o "$WIT_PKG" >/dev/null
)

wasm-tools component embed "$WIT_DIR" "$CORE_WASM" --world "$WORLD_NAME" -o "$EMBEDDED_WASM"
wasm-tools component new "$EMBEDDED_WASM" -o "$OUT"
wasm-tools validate "$OUT" >/dev/null

echo "wrote $OUT"
