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
  # Example: VIBE_WASMTIME_WASM_FLAGS='gc=y component-model-async=y,concurrency-support=y'
  # shellcheck disable=SC2206
  tokens=($raw)
  for token in "${tokens[@]}"; do
    WASMTIME_EXTRA_ARGS+=("$prefix" "$token")
  done
}

exec_wasmtime() {
  if [ "${#WASMTIME_EXTRA_ARGS[@]}" -gt 0 ]; then
    exec "$WASMTIME_BIN" "${WASMTIME_EXTRA_ARGS[@]}" "$@"
  fi
  exec "$WASMTIME_BIN" "$@"
}

exec_wasmtime_run() {
  if [ "${#WASMTIME_EXTRA_ARGS[@]}" -gt 0 ]; then
    exec "$WASMTIME_BIN" run "${WASMTIME_EXTRA_ARGS[@]}" "$@"
  fi
  exec "$WASMTIME_BIN" run "$@"
}

if [ -n "${VIBE_WASMTIME_WASM_FLAGS:-}" ]; then
  append_prefixed_flags "-W" "${VIBE_WASMTIME_WASM_FLAGS}"
fi

if [ -n "${VIBE_WASMTIME_WASI_FLAGS:-}" ]; then
  append_prefixed_flags "-S" "${VIBE_WASMTIME_WASI_FLAGS}"
fi

# Keep compatibility with both styles:
#   wasmtime run ...
#   wasmtime --invoke _start ...
if [ "${1:-}" = "run" ]; then
  shift
  exec_wasmtime_run "$@"
fi

exec_wasmtime "$@"
