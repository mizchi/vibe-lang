#!/usr/bin/env bash
# Build the standalone size-optimizer artifact `vibe-opt.wasm` (#1107 Phase 2).
#
# The in-house optimizer (lib/@vibe/optimizer) is NOT linked into the compiler
# (+~700KB, and the frozen bootstrap seed cannot self-compile the coupled
# pair — the ADR-0070 constraint recorded in docs/wasm-opt-dogfood.md). It
# ships as this separate artifact instead, consumed by `vibe build --minify`
# (runtime/vibe) and scripts/minify_gate.sh.
#
# Usage:
#   bash scripts/build_vibe_opt.sh [out.wasm]     # default: _build/vibe-opt.wasm
#
# The compiler used to build it is, in priority order:
#   $VIBE_OPT_COMPILER > $VIBE_STAGE2_WASM > bootstrap/seed/compiler.wasm
# The committed seed is sufficient — scripts/vibe_opt.vibex only uses
# long-stable builtins (Fs::read_bytes/write_bytes, Env::args_*) plus the
# optimizer package, all of which predate the current seed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/_build/vibe-opt.wasm}"
COMPILER="${VIBE_OPT_COMPILER:-${VIBE_STAGE2_WASM:-$ROOT/bootstrap/seed/compiler.wasm}}"

[ -f "$COMPILER" ] || { echo "build_vibe_opt: compiler wasm not found: $COMPILER" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.diag"

cd "$ROOT"
# VIBE_RC=0 (#1109): build the optimizer on the bump allocator. Under RC the
# free-list search allocator (__rt_rc_alloc) degenerates on the optimizer's
# allocation pattern — a cpu-profile of one minify round over the 1.4MB dist
# CLI showed 97% of wall time inside __rt_rc_alloc. Bump never frees, which
# is fine here: scripts/minify_wasm.sh and the launcher's --minify loop run
# ONE round per process, so memory is reclaimed by instance teardown.
env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RC=0 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
  "$COMPILER" scripts/vibe_opt.vibex "$OUT" main >/dev/null 2>&1 || true

if [ ! -s "$OUT" ]; then
  [ -s "$OUT.diag" ] && cat "$OUT.diag" >&2
  rm -f "$OUT.diag"
  echo "build_vibe_opt: build failed (compiler: $COMPILER)" >&2
  exit 1
fi
rm -f "$OUT.diag" "$OUT.funcmap"
echo "vibe-opt.wasm -> $OUT ($(wc -c <"$OUT") bytes, compiler: $COMPILER)"
