#!/usr/bin/env bash
# golden solutions が現行コンパイラで compile+run し、期待出力と一致するか
# を検証する。言語変更で writability タスクセットが壊れていないかの回帰 gate。
#
# usage: bash eval/lang-review/run_golden.sh
set -uo pipefail

cd "$(dirname "$0")/../.."
GOLDEN_DIR=eval/lang-review/golden
OUT_DIR=_build/evalgolden
mkdir -p "$OUT_DIR"

S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
[ -f "$S2" ] || S2=bootstrap/seed/selfhost_compiler.wasm
echo "[lang-review] compiler: $S2"

pass=0
fail=0
for src in "$GOLDEN_DIR"/*.vibe; do
  [ -e "$src" ] || { echo "[lang-review] no golden solutions yet"; exit 0; }
  name=$(basename "$src" .vibe)
  expected="$GOLDEN_DIR/$name.expected"
  wasm="$OUT_DIR/$name.wasm"
  if ! VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$S2" "$src" "$wasm" main >/dev/null 2>&1; then
    echo "FAIL $name (compile): $(cat "$wasm.diag" 2>/dev/null)"
    fail=$((fail + 1))
    continue
  fi
  actual=$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$wasm" 2>/dev/null)
  if [ -f "$expected" ] && [ "$actual" != "$(cat "$expected")" ]; then
    echo "FAIL $name (output mismatch)"
    echo "  expected: $(head -3 "$expected")"
    echo "  actual:   $(printf '%s' "$actual" | head -3)"
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done

echo "[lang-review] golden: $pass pass / $fail fail"
[ "$fail" -eq 0 ]
