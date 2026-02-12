#!/usr/bin/env bash
# Benchmark i32 vs i64 bitwise operations in WAT
# Measures a single invocation — the 80-iteration loop is inside the module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve wasmtime binary
if command -v wasmtime &>/dev/null; then
  WT=wasmtime
elif [ -x deps/wasmtime/target/release/wasmtime ]; then
  WT=deps/wasmtime/target/release/wasmtime
else
  echo "wasmtime not found" >&2; exit 1
fi

echo "=== WAT i32 vs i64 single-invocation benchmark ==="
echo ""

echo "--- i32 (native 32-bit rotl) ---"
RESULT_I32=$($WT run --invoke run "$SCRIPT_DIR/int_width_i32.wat" 2>&1)
echo "  result: $RESULT_I32"
echo ""

echo "--- i64 (64-bit with manual rotate + mask) ---"
RESULT_I64=$($WT run --invoke run "$SCRIPT_DIR/int_width_i64.wat" 2>&1)
echo "  result: $RESULT_I64"
echo ""

echo "(WAT modules run 80 rounds each internally."
echo " For meaningful timing, use hyperfine or embed in a loop module.)"
echo ""

# If hyperfine is available, use it for accurate comparison
if command -v hyperfine &>/dev/null; then
  echo "=== hyperfine comparison ==="
  hyperfine --warmup 5 \
    "$WT run --invoke run $SCRIPT_DIR/int_width_i32.wat" \
    "$WT run --invoke run $SCRIPT_DIR/int_width_i64.wat"
else
  echo "(Install hyperfine for accurate timing comparison)"
  echo ""
  echo "Manual timing (100 invocations each):"
  echo ""
  N=100

  echo "--- i32 x${N} ---"
  START=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.monotonic()*1e9))')
  for _ in $(seq 1 "$N"); do
    $WT run --invoke run "$SCRIPT_DIR/int_width_i32.wat" > /dev/null 2>&1
  done
  END=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.monotonic()*1e9))')
  MS_I32=$(python3 -c "print(f'{($END - $START)/1e6:.1f}')")
  echo "  ${N} invocations: ${MS_I32} ms"

  echo "--- i64 x${N} ---"
  START=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.monotonic()*1e9))')
  for _ in $(seq 1 "$N"); do
    $WT run --invoke run "$SCRIPT_DIR/int_width_i64.wat" > /dev/null 2>&1
  done
  END=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.monotonic()*1e9))')
  MS_I64=$(python3 -c "print(f'{($END - $START)/1e6:.1f}')")
  echo "  ${N} invocations: ${MS_I64} ms"

  RATIO=$(python3 -c "print(f'{float($MS_I64)/float($MS_I32):.2f}')")
  echo ""
  echo "=== i64/i32 ratio = ${RATIO}x (startup overhead dominated) ==="
fi
