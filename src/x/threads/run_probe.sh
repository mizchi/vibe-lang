#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WAT_PATH="$SCRIPT_DIR/wasi_threads_probe.wat"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xsh_wasi_threads_probe.XXXXXX")"
WASM_PATH="$TMP_DIR/wasi_threads_probe.wasm"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required. install: cargo install wasm-tools" >&2
  exit 1
fi

if [ ! -f "$WAT_PATH" ]; then
  echo "probe wat not found: $WAT_PATH" >&2
  exit 1
fi

wasm-tools parse "$WAT_PATH" -o "$WASM_PATH"

: "${XSH_WASMTIME_WASM_FLAGS:=threads=y shared-memory=y}"
: "${XSH_WASMTIME_WASI_FLAGS:=threads=y}"

echo "WAT: $WAT_PATH"
echo "WASM: $WASM_PATH"
echo "XSH_WASMTIME_WASM_FLAGS=$XSH_WASMTIME_WASM_FLAGS"
echo "XSH_WASMTIME_WASI_FLAGS=$XSH_WASMTIME_WASI_FLAGS"

XSH_WASMTIME_WASM_FLAGS="$XSH_WASMTIME_WASM_FLAGS" \
XSH_WASMTIME_WASI_FLAGS="$XSH_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" run "$WASM_PATH"
