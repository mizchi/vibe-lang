#!/usr/bin/env bash
# Measure per-iteration heap growth of a selfhost-compiled allocating loop.
#
# The selfhost linear backend bump-allocates and (today) never frees, so an
# allocating loop's heap grows linearly with the iteration count — i.e. it
# leaks. This script compiles the same loop at two iteration counts with the
# *selfhost* backend, reads the exported `__heap_ptr` after running each on a
# minimal wasm host, and reports the bytes leaked per iteration.
#
#   per-iteration bytes = (heap_used(N2) - heap_used(N1)) / (N2 - N1)
#
# Baseline (bump allocator): a positive constant (one allocation/iteration,
# never reclaimed). Once Perceus RC + free-list land (Phase 3) this should drop
# to ~0 (the heap is reused). Pass a threshold as $1 to fail when exceeded
# (for use as a leak gate); omit it to just print the report.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

THRESHOLD="${1:-}"
N1="${VIBE_HEAP_LEAK_N1:-1000}"
N2="${VIBE_HEAP_LEAK_N2:-11000}"

# shellcheck source=/dev/null
source scripts/ensure_native_cli.sh
VIBE_BIN="${VIBE_CLI_BIN:-$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe}"

PROBE="$PROJECT_ROOT/vibe/compiler/_heap_leak_probe_test.vibe"
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

cat > "$PROBE" <<EOF
import ./codegen_test_support.vibe { compile_wasi }
import ./core/polyfill.vibe { __to_string }
let emit: (Int) -> Int with { Error, Fs } = (n) -> {
  let src = "let main: () -> Int = () -> {\n  let mut sum = 0\n  let mut i = 0\n  while i < " + __to_string(n) + " {\n    let t = (i, i + 1)\n    sum = sum + t.0\n    i = i + 1\n  }\n  sum\n}"
  Fs::write_bytes("/tmp/_heap_leak_" + __to_string(n) + ".wasm", compile_wasi(src, "main"))
  0
}
test "emit heap leak probe" {
  emit($N1)
  emit($N2)
  assert(true)
}
EOF

"$VIBE_BIN" test "$PROBE" >/dev/null 2>&1

used1="$(node scripts/measure_selfhost_heap.mjs "/tmp/_heap_leak_${N1}.wasm" main | node -e 'process.stdin.once("data",d=>console.log(JSON.parse(d).heap_used))')"
used2="$(node scripts/measure_selfhost_heap.mjs "/tmp/_heap_leak_${N2}.wasm" main | node -e 'process.stdin.once("data",d=>console.log(JSON.parse(d).heap_used))')"

per_iter="$(node -e "console.log((($used2)-($used1))/(($N2)-($N1)))")"

echo "selfhost heap leak measurement:"
echo "  iterations $N1 -> heap_used $used1 bytes"
echo "  iterations $N2 -> heap_used $used2 bytes"
echo "  per-iteration growth: $per_iter bytes"

if [ -n "$THRESHOLD" ]; then
  over="$(node -e "console.log((($per_iter) > ($THRESHOLD)) ? 1 : 0)")"
  if [ "$over" = "1" ]; then
    echo "FAIL: per-iteration growth $per_iter exceeds threshold $THRESHOLD (heap leak)"
    exit 1
  fi
  echo "OK: per-iteration growth within threshold $THRESHOLD"
fi
