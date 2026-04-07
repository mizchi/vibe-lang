#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_COMPONENT="${1:-$PROJECT_ROOT/dist/selfhost_check_preview2.component.wasm}"
OUT_WIT="${2:-${OUT_COMPONENT%.wasm}.wit}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_check_component_entry.vibe}"
VIBE_EXE="${VIBE_EXE:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd wasm-tools

if [ ! -x "$VIBE_EXE" ]; then
  moon build --target native --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe >/dev/null
fi

mkdir -p "$(dirname "$OUT_COMPONENT")" "$(dirname "$OUT_WIT")"

"$VIBE_EXE" compile --component-string-lift "$ENTRY_PATH" -o "$OUT_COMPONENT"
wasm-tools validate --features exceptions "$OUT_COMPONENT" >/dev/null
wasm-tools component wit "$OUT_COMPONENT" >"$OUT_WIT"

echo "wrote $OUT_COMPONENT"
echo "wrote $OUT_WIT"
