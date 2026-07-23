#!/usr/bin/env bash
# #1056 (almide docs/BENCHMARKS.md comparison): wasm binary-size regression
# bench. Compiles each bench/binary_size/*.vibe program with the linear
# backend, RC off (VIBE_RC=0) and RC on (VIBE_RC=1), and reports the "as
# shipped" byte size for each -- plus, best-effort, the size after
# `wasm-opt -Oz` when that binary is available on PATH (it is optional, as
# in almide's own methodology; this environment does not ship it, so that
# column reads "n/a" here).
#
#   bash scripts/bench_binary_size.sh [cli.wasm]
#
# cli.wasm defaults to the committed seed (bootstrap/seed/compiler.wasm).
# Pass a freshly-built stage1/stage2 (scripts/generations.sh build) to
# measure a compiler change before it is folded into a new seed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash scripts/ensure_seed.sh >/dev/null
CLI_WASM="${1:-bootstrap/seed/compiler.wasm}"
[ -s "$CLI_WASM" ] || { echo "bench_binary_size: no such compiler wasm: $CLI_WASM" >&2; exit 2; }

BENCH_DIR="$ROOT_DIR/bench/binary_size"
OUT_DIR="$ROOT_DIR/_build/bench_binary_size"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

have_wasm_opt=0
if command -v wasm-opt >/dev/null 2>&1; then
  have_wasm_opt=1
fi

printf '%-20s %12s %12s %14s\n' "program" "rc_off" "rc_on" "rc_off -Oz"
printf '%-20s %12s %12s %14s\n' "-------" "------" "-----" "----------"

for src in "$BENCH_DIR"/*.vibe; do
  name="$(basename "$src" .vibe)"
  sz_off=0
  sz_on=0
  for rc in 0 1; do
    out="$OUT_DIR/${name}.rc${rc}.wasm"
    VIBE_RC="$rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
      "$src" "$out" main >"$OUT_DIR/${name}.rc${rc}.log" 2>&1 || true
    if [ ! -s "$out" ]; then
      echo "bench_binary_size: FAIL: $name did not compile under VIBE_RC=$rc" >&2
      tail -20 "$OUT_DIR/${name}.rc${rc}.log" >&2
      exit 1
    fi
    sz="$(wc -c <"$out")"
    if [ "$rc" = "0" ]; then
      sz_off="$sz"
    else
      sz_on="$sz"
    fi
  done
  opt_col="n/a"
  if [ "$have_wasm_opt" = "1" ]; then
    opt_out="$OUT_DIR/${name}.rc0.opt.wasm"
    if wasm-opt -Oz --all-features "$OUT_DIR/${name}.rc0.wasm" -o "$opt_out" 2>"$OUT_DIR/${name}.opt.log"; then
      opt_col="$(wc -c <"$opt_out")"
    else
      opt_col="opt-failed"
    fi
  fi
  printf '%-20s %12s %12s %14s\n' "$name" "$sz_off" "$sz_on" "$opt_col"
done
