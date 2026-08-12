#!/usr/bin/env bash
# Execute the compiler root unit tests through compiler-owned exact-path
# exposure (#1633). The extraction tool removes package/type imports; this
# wrapper restores exact-file imports for every compiler immutable value used
# by each generated driver. No flat compiler text is concatenated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SEED="${VIBE_COV_SEED:-bootstrap/seed/compiler.wasm}"
OUTDIR="${VIBE_COV_DIR:-_build/coverage/selfhost-corpus}"
ACC="$OUTDIR/acc.json"
COMPILER_COV="$OUTDIR/compiler_cov.wasm"
COMPILER_ENTRY="lib/@vibe/compiler/cli_adapter.vibe"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
OUT="_build/coverage/selfhost-ut"
export VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --experimental-wasm-inlining --stack-size=131072}"

[ -s "$ACC" ] || { echo "ut: run coverage_corpus.sh first (no acc.json)" >&2; exit 1; }
[ -s "$COMPILER_COV" ] || { echo "ut: run coverage_corpus.sh first (no current compiler_cov.wasm)" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 source scripts/coverage_drivers.sh

exact_imports() { # test basename
  case "$1" in
    cfv_test.vibe)
      printf 'import ../../../../lib/@vibe/compiler/codegen/common_analysis/common_analysis.vibe { collect_free_vars }\n'
      printf 'let array_empty: [T]() -> Array[T] = () -> { Array::slice([], 0, 0) }\n'
      ;;
    cfv_encl_test.vibe)
      printf 'import ../../../../lib/@vibe/compiler/codegen/common_analysis/common_analysis.vibe { collect_free_vars_indexed_self }\n'
      ;;
    pctor_test.vibe|pctor2_test.vibe)
      printf 'import ../../../../lib/@vibe/compiler/codegen/codegen.vibe { compile_wasi_module }\n'
      printf 'import ../../../../lib/@vibe/parser/lexer.vibe { lex }\n'
      printf 'import ../../../../lib/@vibe/parser/parser.vibe { parse_program }\n'
      ;;
    *) return 1 ;;
  esac
}

ok=0
for f in lib/@vibe/compiler/*_test.vibe; do
  base="$(basename "$f")"
  d="$OUT/${base%.vibe}"; mkdir -p "$d"
  generated="$d/generated.vibe"
  bash scripts/coverage_unittests_run.sh "" "$base" "$generated" >"$d/generate.log" 2>&1 || {
    echo "[ut:$base] driver generation failed" >&2; cat "$d/generate.log" >&2; exit 1
  }
  grep -q 'cov_ut_1:' "$generated" || { echo "[ut:$base] generated no tests" >&2; exit 1; }
  { exact_imports "$base"; cat "$generated"; } > "$d/driver.vibe"
  if [ "$base" = pctor_test.vibe ]; then
    # The extracted test performs the same Fs write as its source declaration;
    # the historical extractor retains Exception but cannot infer capability rows.
    sed -e 's/) -> Int with Exception =/) -> Int with Exception + Fs::write_bytes =/' -e 's/let cov_driver_main: () -> Int =/let cov_driver_main: () -> Int with Fs::write_bytes =/' "$d/driver.vibe" > "$d/driver.tmp"
    mv "$d/driver.tmp" "$d/driver.vibe"
  fi
  rm -f "$d/src.vibe" "$d/src.vibe.diag"
  VIBE_EMIT_COVERAGE_DRIVER_SOURCE=1 VIBE_COVERAGE_DRIVER_PATH="$d/driver.vibe" \
    VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_COV" \
    "$COMPILER_ENTRY" "$d/src.vibe" cov_driver_main >"$d/expose.log" 2>&1 || true
  [ -s "$d/src.vibe" ] || { echo "[ut:$base] exact-path exposure failed" >&2; cat "$d/src.vibe.diag" 2>/dev/null >&2 || tail -3 "$d/expose.log" >&2; exit 1; }
  compile_status=0
  coverage_driver_compile_with_retries "$d" cov_driver_main || compile_status=$?
  [ "$compile_status" = 0 ] || { echo "[ut:$base] compile failed (status $compile_status)" >&2; cat "$d/m.wasm.diag" 2>/dev/null >&2 || tail -3 "$d/compile.log" >&2; exit 1; }
  cov="$d/cov.json"
  VIBE_COV_OUT="$cov" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" --invoke _start "$d/m.wasm" >"$d/run.log" 2>&1 || {
    echo "[ut:$base] execution failed" >&2; tail -5 "$d/run.log" >&2; exit 1
  }
  [ -s "$cov" ] || { echo "[ut:$base] run produced no raw coverage" >&2; exit 1; }
  merge_stat="$(coverage_driver_merge_checked "$ACC" "$cov")" || { echo "[ut:$base] checked coverage merge failed" >&2; exit 1; }
  echo "[ut:$base] $merge_stat"
  ok=$((ok + 1))
done
[ "$ok" -gt 0 ] || { echo "ut: no root test driver ran" >&2; exit 1; }
echo "[ut] $ok exact-path test files ran and merged" >&2
