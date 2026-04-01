#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref}"

if ! command -v node >/dev/null 2>&1; then
  echo "run_wasm_vibe_host_runner.sh: node not found" >&2
  exit 1
fi

node_flags=()
if [ -n "$VIBE_NODE_WASM_FLAGS" ]; then
  # shellcheck disable=SC2206
  node_flags=($VIBE_NODE_WASM_FLAGS)
fi

exec node "${node_flags[@]}" "$PROJECT_ROOT/scripts/wasm_vibe_host_runner.js" "$@"
