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

# Newer Node/V8 releases remove graduated --experimental-wasm-* flags (Node 24
# dropped --experimental-wasm-inlining; the features are simply on by default),
# and node hard-fails on unknown options. Probe each flag once per node
# version and cache the accepted set, so the runner works across versions
# without giving up the perf flags where they still exist.
node_flags=()
if [ -n "$VIBE_NODE_WASM_FLAGS" ]; then
  node_ver="$(node -v 2>/dev/null || echo unknown)"
  flag_cache="${TMPDIR:-/tmp}/vibe_node_wasm_flags_${node_ver}_$(printf '%s' "$VIBE_NODE_WASM_FLAGS" | tr -c 'A-Za-z0-9' '_')"
  if [ -f "$flag_cache" ]; then
    # shellcheck disable=SC2207
    node_flags=($(cat "$flag_cache"))
  else
    accepted=""
    for f in $VIBE_NODE_WASM_FLAGS; do
      if node "$f" -e "" >/dev/null 2>&1; then
        accepted="$accepted $f"
        node_flags+=("$f")
      fi
    done
    printf '%s\n' "$accepted" > "$flag_cache" 2>/dev/null || true
  fi
fi

exec node "${node_flags[@]}" "$PROJECT_ROOT/scripts/wasm_vibe_host_runner.js" "$@"
