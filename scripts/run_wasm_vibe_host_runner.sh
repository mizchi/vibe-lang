#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# #721: --experimental-wasm-inlining puts V8's wasm-to-wasm inliner on for
# MVP (non-GC) modules too -- V8 enables it by default only for modules that
# contain GC types, which made the wasm-gc backend look ~35% faster than the
# linear backend on call-heavy code (fib(38): 0.27s -> 0.15s) even though the
# emitted function bodies are byte-identical. Same precedent as the
# unconditional exnref flag above it.
VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --experimental-wasm-inlining}"

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
