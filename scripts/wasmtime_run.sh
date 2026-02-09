#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WASMTIME_BIN="${WASMTIME_BIN:-$("$SCRIPT_DIR/wasmtime_bin.sh")}"

WASMTIME_EXTRA_ARGS=()

append_prefixed_flags() {
  local prefix="$1"
  local raw="$2"
  local token
  local -a tokens=()
  # Intentionally split on shell whitespace so multiple flags can be passed.
  # Example: XSH_WASMTIME_WASM_FLAGS='gc=y component-model-async=y,concurrency-support=y'
  # shellcheck disable=SC2206
  tokens=($raw)
  for token in "${tokens[@]}"; do
    WASMTIME_EXTRA_ARGS+=("$prefix" "$token")
  done
}

if [ -n "${XSH_WASMTIME_WASM_FLAGS:-}" ]; then
  append_prefixed_flags "-W" "${XSH_WASMTIME_WASM_FLAGS}"
fi

if [ -n "${XSH_WASMTIME_WASI_FLAGS:-}" ]; then
  append_prefixed_flags "-S" "${XSH_WASMTIME_WASI_FLAGS}"
fi

# Keep compatibility with both styles:
#   wasmtime run ...
#   wasmtime --invoke run ...
if [ "${1:-}" = "run" ]; then
  shift
  exec "$WASMTIME_BIN" run "${WASMTIME_EXTRA_ARGS[@]}" "$@"
fi

exec "$WASMTIME_BIN" "${WASMTIME_EXTRA_ARGS[@]}" "$@"
