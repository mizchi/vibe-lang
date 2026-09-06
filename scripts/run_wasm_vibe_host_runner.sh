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

# #2134: node's default JS stack (~1 MB) is what caps a module's top-level
# declaration count -- nothing in the compiler does. The checker recurses once
# per top-level statement, so a VALID file stops compiling at ~1300
# declarations (1200 ok, 1400 fail, 3/3 each way), and the SIZE of each
# declaration is irrelevant: the bodies here are `x + 0`. The relationship is
# linear in the stack -- `--stack-size=4000` moves the same ceiling to ~5000
# declarations (3000 and 5000 ok, 8000 not).
#
# Measure this ONLY on content that has never compiled before. One successful
# compile writes a persistent `_build/vibe_selfhost_module_header_v2_*` row,
# and from then on that exact source compiles on the default stack -- so
# re-probing a file you already got through reports a ceiling several times
# too high (this cost three wrong numbers in #2134 before the cache was
# spotted). scripts/check_declaration_scale.sh generates unique content per run.
#
# The value is bounded by the OS thread stack, because a --stack-size larger
# than the thread's own stack makes node SEGFAULT instead of raising a
# catchable RangeError -- turning a legible diagnostic into a crash. Half of
# `ulimit -s` leaves room for the C++ frames V8 interleaves with JS ones.
if [ -z "${VIBE_NODE_STACK_SIZE:-}" ]; then
  vibe_ulimit_kb="$(ulimit -s 2>/dev/null || echo 8192)"
  case "$vibe_ulimit_kb" in
    ''|*[!0-9]*) VIBE_NODE_STACK_SIZE=4000 ;;
    *)
      vibe_half=$((vibe_ulimit_kb / 2))
      if [ "$vibe_half" -lt 4000 ]; then
        VIBE_NODE_STACK_SIZE="$vibe_half"
      else
        VIBE_NODE_STACK_SIZE=4000
      fi
      ;;
  esac
fi
# node takes the LAST --stack-size wins (measured), so appending ours after a
# caller's own would silently OVERRIDE it. scripts/generations.sh passes
# `--stack-size=131072` through VIBE_NODE_WASM_FLAGS for the bootstrap
# compiles, and appending 4000 after it would cut a deliberate 128 MB stack to
# 4 MB -- a 32x margin removed, invisibly, in the one place that needs it most.
# A caller who named a size owns the decision.
vibe_caller_set_stack=0
case " ${node_flags[*]-} " in
  *" --stack-size="*) vibe_caller_set_stack=1 ;;
esac
# Below node's own default (~984 KB) the flag would LOWER the ceiling, so only
# raise it. `VIBE_NODE_STACK_SIZE=0` disables it (used by the gate's Red case).
if [ "$vibe_caller_set_stack" -eq 0 ] && [ "${VIBE_NODE_STACK_SIZE}" -gt 1200 ] 2>/dev/null; then
  node_flags+=("--stack-size=${VIBE_NODE_STACK_SIZE}")
fi

# VIBE_NODE_EXTRA_FLAGS is appended verbatim (no probe, no cache): flags a
# caller knows its node accepts, such as --cpu-prof for scripts/profile_compile.sh,
# which needs the perf flags above on the profiled process too -- a direct
# `node --cpu-prof` skips them and profiles a compiler V8 never inlines.
# One flag per LINE, so a value may contain spaces (`--cpu-prof-dir=/a dir`
# stays one argument); a newline cannot be part of a flag.
extra_flags=()
if [ -n "${VIBE_NODE_EXTRA_FLAGS:-}" ]; then
  while IFS= read -r vibe_extra_line || [ -n "$vibe_extra_line" ]; do
    if [ -n "$vibe_extra_line" ]; then
      extra_flags+=("$vibe_extra_line")
    fi
  done <<VIBE_EXTRA_EOF
$VIBE_NODE_EXTRA_FLAGS
VIBE_EXTRA_EOF
fi

exec node "${node_flags[@]}" ${extra_flags[@]+"${extra_flags[@]}"} "$PROJECT_ROOT/scripts/wasm_vibe_host_runner.js" "$@"
