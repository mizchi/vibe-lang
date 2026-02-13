#!/usr/bin/env bash
set -euo pipefail

WASM_PATH="${1:-wasm/vibe/vibe.wasm}"

if [ ! -f "$WASM_PATH" ]; then
  echo "missing wasm artifact: $WASM_PATH" >&2
  exit 1
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "wasmtime not found in PATH" >&2
  exit 1
fi

OUT="$(
  wasmtime run \
    -W gc=y \
    -W function-references=y \
    --invoke vibe_check \
    "$WASM_PATH" \
    1024 0 4096 4096
)"

LAST_LINE="$(printf '%s\n' "$OUT" | tail -n1)"
case "$LAST_LINE" in
  '' | *[!0-9]*)
    echo "unexpected wasmtime output: $OUT" >&2
    exit 1
    ;;
esac

if [ "$LAST_LINE" -le 0 ]; then
  echo "unexpected out_len: $LAST_LINE" >&2
  exit 1
fi

echo "ok: wasmtime invoke vibe_check out_len=$LAST_LINE"
