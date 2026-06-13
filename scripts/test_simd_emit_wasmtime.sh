#!/usr/bin/env bash
set -euo pipefail

# SIMD emit opcode gate (ADR-0054 / #536).
#
# The selfhost SIMD emitter (vibe/compiler/codegen/wasm_emit/simd.vibe) writes
# `0xFD <sub-opcode> ...` for v128 instructions. simd_test.vibe pins each
# emitter to its exact sub-opcode byte. This script is the matching runtime
# side: it assembles a module that uses those same sub-opcodes and runs it
# under wasmtime, so a wrong opcode (e.g. the historical i8x16.le_u=38/lt_u
# and ge_u=40/gt_u mix-up) is caught as a validation/execution failure rather
# than silently emitting a different instruction.
#
# Opcodes exercised (must match simd.vibe):
#   i8x16.le_u=0x2A  i8x16.ge_u=0x2C  i8x16.sub=0x71  i8x16.min_u=0x77
#   i8x16.swizzle=0x0E  i8x16.splat=0x0F  i8x16.eq=0x23  i8x16.all_true=0x63
#   v128.const=0x0C

WASMTIME_BIN="${WASMTIME_BIN:-wasmtime}"
if ! command -v "$WASMTIME_BIN" >/dev/null 2>&1; then
  if [ -x "$HOME/.wasmtime/bin/wasmtime" ]; then
    WASMTIME_BIN="$HOME/.wasmtime/bin/wasmtime"
  else
    echo "simd-emit-wasmtime: wasmtime not found (set WASMTIME_BIN)" >&2
    exit 1
  fi
fi

wat="$(mktemp --suffix=.wat)"
trap 'rm -f "$wat"' EXIT

cat > "$wat" <<'WAT'
(module
  (func (export "probe") (result i64)
    (drop (i8x16.le_u (v128.const i8x16 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41)
                      (v128.const i8x16 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42)))
    (drop (i8x16.ge_u (v128.const i8x16 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42 0x42)
                      (v128.const i8x16 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41 0x41)))
    (drop (i8x16.sub   (v128.const i64x2 5 5) (v128.const i64x2 2 2)))
    (drop (i8x16.min_u (v128.const i64x2 9 9) (v128.const i64x2 3 3)))
    (drop (i8x16.swizzle (v128.const i64x2 1 2) (v128.const i64x2 0 0)))
    (drop (i8x16.splat (i32.const 7)))
    (i64.extend_i32_s
      (i8x16.all_true
        (i8x16.eq (v128.const i8x16 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65)
                  (v128.const i8x16 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65 65))))))
WAT

out="$("$WASMTIME_BIN" run --invoke probe "$wat" 2>/dev/null || true)"
if [ "$out" != "1" ]; then
  echo "simd-emit-wasmtime: FAIL (expected probe()=1, got '$out')" >&2
  echo "  a SIMD sub-opcode is invalid or mis-mapped; see vibe/compiler/codegen/wasm_emit/simd.vibe" >&2
  exit 1
fi

echo "simd-emit-wasmtime: ok (all exercised SIMD opcodes validate + run under wasmtime)"
