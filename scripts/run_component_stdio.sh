#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <input.vibe> [output.component.wasm] [invoke-signature]" >&2
  echo "example: $0 lib/@vibe/builtin/test_import_test.vibe" >&2
  echo "example: $0 lib/@vibe/builtin/test_import_test.vibe /tmp/out.component.wasm 'run()'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
WASMTIME_BIN="${WASMTIME_BIN:-$(scripts/wasmtime_bin.sh)}"
WASMTIME_RUN="scripts/wasmtime_run.sh"

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
WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke "$INVOKE" "$COMPONENT"
