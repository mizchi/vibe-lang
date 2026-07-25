#!/usr/bin/env bash
# minify_gate.sh — semantics-preservation gate for the standalone size
# optimizer `vibe-opt.wasm` (#1107 Phase 2).
#
# For each corpus program:
#   1. compile it to wasm with the current compiler (seed or $VIBE_STAGE2_WASM),
#   2. run the baseline and capture stdout + exit code,
#   3. minify with vibe-opt.wasm,
#   4. wasmtime-validate the minified module (exceptions enabled — vibe
#      effects compile to wasm EH),
#   5. run the minified module and require identical stdout + exit code,
#   6. require the minified module to be no larger than the baseline.
#
# Any mismatch fails the gate. This is the check that historically caught the
# `throw`/`try_table` immediate-decoding bug (docs/wasm-opt-dogfood.md) —
# inline fixtures alone had no exception handling and missed it.
#
# Usage: bash scripts/minify_gate.sh [file.vibe ...]
#   default corpus: the examples below (effectful + pure + string-heavy).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${VIBE_STAGE2_WASM:-$ROOT/bootstrap/seed/compiler.wasm}"
RUN="bash $ROOT/scripts/run_wasm_vibe_host_runner.sh"
WORK="$(mktemp -d -t vibe-minify-gate-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

OPT_WASM="${VIBE_OPT_WASM:-$ROOT/_build/vibe-opt.wasm}"
if [ ! -f "$OPT_WASM" ]; then
  bash "$ROOT/scripts/build_vibe_opt.sh" "$OPT_WASM" || exit 1
fi

if [ "$#" -ge 1 ]; then
  CORPUS=("$@")
else
  # Effectful (wasm-EH) + pure + closure/call_indirect + variant/float +
  # string-heavy coverage. Every entry must define a `main` entry function.
  CORPUS=(
    examples/perform_handle.vibe
    examples/compiler_features.vibe
    bench/binary_size/hello_world.vibe
    bench/binary_size/fib.vibe
    bench/binary_size/fizzbuzz.vibe
    bench/binary_size/closure_indirect.vibe
    bench/binary_size/variant_float.vibe
  )
fi

fail=0
for src in "${CORPUS[@]}"; do
  name="$(basename "$src" .vibe)"
  base="$WORK/$name.wasm"
  min="$WORK/$name.min.wasm"

  if ! env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      $RUN --invoke cli_main "$COMPILER" "$src" "$base" main >/dev/null 2>&1 \
      || [ ! -s "$base" ]; then
    echo "[minify-gate] FAIL(compile): $src"; fail=1; continue
  fi

  $RUN "$base" >"$WORK/$name.base.out" 2>/dev/null; base_rc=$?
  if ! $RUN "$OPT_WASM" "$base" "$min" >"$WORK/$name.opt.log" 2>&1 || [ ! -s "$min" ]; then
    echo "[minify-gate] FAIL(minify): $src"; sed -n 1,5p "$WORK/$name.opt.log"; fail=1; continue
  fi
  if ! wasmtime compile -W exceptions=y "$min" -o /dev/null >/dev/null 2>&1; then
    echo "[minify-gate] FAIL(validate): $src"; fail=1; continue
  fi
  $RUN "$min" >"$WORK/$name.min.out" 2>/dev/null; min_rc=$?
  if [ "$base_rc" != "$min_rc" ]; then
    echo "[minify-gate] FAIL(exit): $src baseline=$base_rc minified=$min_rc"; fail=1; continue
  fi
  if ! cmp -s "$WORK/$name.base.out" "$WORK/$name.min.out"; then
    echo "[minify-gate] FAIL(stdout): $src"
    diff "$WORK/$name.base.out" "$WORK/$name.min.out" | head -5
    fail=1; continue
  fi
  bsz="$(wc -c <"$base")"; msz="$(wc -c <"$min")"
  if [ "$msz" -gt "$bsz" ]; then
    echo "[minify-gate] FAIL(grew): $src ${bsz}B -> ${msz}B"; fail=1; continue
  fi
  pct=$(( (bsz - msz) * 100 / bsz ))
  echo "[minify-gate] ok: $src ${bsz}B -> ${msz}B (-${pct}%)"
done

if [ "$fail" = "0" ]; then
  echo "[minify-gate] ALL OK"
else
  echo "[minify-gate] FAILURES PRESENT"
fi
exit "$fail"
