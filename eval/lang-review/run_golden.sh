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

# The subject of this eval is the CURRENT compiler's diagnostic text, so the
# compiler that answers has to be the current one. `$LANG_REVIEW_STAGE2` is how
# the gate lane hands over the stage2 it already resolved (tests/gates/lib.sh
# `gate_resolve_stage2`): without it this script did its own, weaker lookup,
# found no generations/ tree in CI -- the lane builds into _build/_gate_lane_gen
# -- and silently measured the COMMITTED SEED. A diagnostic reworded in the
# checkout then failed here while passing locally, which is the "which compiler
# answered?" trap in AGENTS.md, from the reporting side.
S2="${LANG_REVIEW_STAGE2:-}"
if [ -z "$S2" ] || [ ! -f "$S2" ]; then
  S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
  [ -f "$S2" ] || S2=bootstrap/seed/compiler.wasm
fi
if [ "$S2" = "bootstrap/seed/compiler.wasm" ]; then
  echo "[lang-review] NOTE: no stage2 available -- measuring the COMMITTED SEED." >&2
  echo "[lang-review] A diagnostic changed in this checkout is invisible to it. Pass" >&2
  echo "[lang-review] LANG_REVIEW_STAGE2=<stage2.wasm> to measure the current compiler." >&2
fi
echo "[lang-review] compiler: $S2"

pass=0
fail=0
for src in "$GOLDEN_DIR"/*.vibe; do
  [ -e "$src" ] || { echo "[lang-review] no golden solutions yet"; exit 0; }
  name=$(basename "$src" .vibe)
  expected="$GOLDEN_DIR/$name.expected"
  wasm="$OUT_DIR/$name.wasm"
  if ! VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
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
