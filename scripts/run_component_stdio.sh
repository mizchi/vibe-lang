#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <input.xsh> [output.component.wasm] [invoke-signature]" >&2
  echo "example: $0 examples/std/test_import.xsh" >&2
  echo "example: $0 examples/std/test_import.xsh /tmp/out.component.wasm 'run()'" >&2
  exit 1
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

INPUT="$1"
OUT="${2:-}"
INVOKE="${3:-run()}"

if [ -n "$OUT" ]; then
  scripts/component_wkg_stdio.sh "$INPUT" "$OUT"
  COMPONENT="$OUT"
else
  BASE="$(basename "$INPUT")"
  BASE="${BASE%.*}"
  COMPONENT="dist/${BASE}.component.wasm"
  scripts/component_wkg_stdio.sh "$INPUT" "$COMPONENT"
fi

# Note: non-command components are invoked explicitly.
wasmtime --invoke "$INVOKE" "$COMPONENT"
