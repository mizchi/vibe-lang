#!/usr/bin/env bash
# repair コーパスの二方向ラチェット。repair_convergence (rubric 8軸目) の
# スコアが依拠している実測が、まだその通りかを検証する。
#
#   diag.grep があるケース  -> broken.vibe は compile FAIL し、診断に
#                              grep パターンが全て含まれること
#   silent があるケース      -> broken.vibe は compile SUCCEED すること
#                              (診断が出ないこと自体が測定対象)
#   全ケース共通            -> fixed.vibe は compile+run し、fixed.expected と一致
#
# **両方向で落とす**: 診断が消えた/文言が変わった場合だけでなく、silent ケースに
# 診断が付くようになった場合も FAIL する。後者は改善なので、silent マーカーを
# 外し diag.grep を書き、スコアを付け直してから通す (scripts/vibe_fmt_allowlist.txt
# と同じラチェット規律)。
#
# usage: bash eval/lang-review/run_repair.sh
set -uo pipefail

cd "$(dirname "$0")/../.."
REPAIR_DIR=eval/lang-review/repair
OUT_DIR=_build/evalrepair
mkdir -p "$OUT_DIR"

S2=$(ls -td _build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm
[ -f "$S2" ] || S2=bootstrap/seed/compiler.wasm
echo "[lang-review] compiler: $S2"

# compile <src> <out> <entry> -> 0 = ok, 1 = fail (診断は "$out".diag)
compile() {
  VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$S2" "$1" "$2" "$3" >/dev/null 2>&1
}

pass=0
fail=0
for dir in "$REPAIR_DIR"/*/; do
  [ -f "$dir/broken.vibe" ] || continue
  name=$(basename "$dir")
  entry=$(cat "$dir/entry" 2>/dev/null || echo main)
  ok=1

  # --- broken 側 ---
  bwasm="$OUT_DIR/$name.broken.wasm"
  if compile "$dir/broken.vibe" "$bwasm" "$entry"; then
    bstatus=ok
  else
    bstatus=fail
  fi

  if [ -f "$dir/silent" ]; then
    if [ "$bstatus" != "ok" ]; then
      echo "FAIL $name: silent ケースに診断が付いた (改善)。silent を消して"
      echo "     diag.grep を書き、scores を付け直してから通すこと:"
      sed 's/^/       /' "$bwasm.diag" 2>/dev/null | head -3
      ok=0
    fi
  else
    if [ "$bstatus" = "ok" ]; then
      echo "FAIL $name: broken.vibe が compile を通った (診断が消えた)"
      ok=0
    else
      while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        if ! grep -qF -- "$pat" "$bwasm.diag" 2>/dev/null; then
          echo "FAIL $name: 診断に期待文字列が無い: $pat"
          echo "     actual: $(head -c 300 "$bwasm.diag" 2>/dev/null)"
          ok=0
        fi
      done < "$dir/diag.grep"
    fi
  fi

  # --- fixed 側 ---
  fwasm="$OUT_DIR/$name.fixed.wasm"
  if ! compile "$dir/fixed.vibe" "$fwasm" "$entry"; then
    echo "FAIL $name: fixed.vibe が compile しない: $(head -c 300 "$fwasm.diag" 2>/dev/null)"
    ok=0
  else
    actual=$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fwasm" 2>/dev/null)
    if [ "$actual" != "$(cat "$dir/fixed.expected")" ]; then
      echo "FAIL $name: fixed.vibe の出力不一致"
      echo "     expected: $(head -3 "$dir/fixed.expected")"
      echo "     actual:   $(printf '%s' "$actual" | head -3)"
      ok=0
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "[lang-review] repair: $pass pass / $fail fail"
[ "$fail" -eq 0 ]
