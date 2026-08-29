#!/usr/bin/env bash
# measure_backend_code_size.sh — linear backend と wasm-gc backend の
# 生成 wasm サイズを同一ソースで比較する (docs/wasm/code-size-linear-vs-gc.md)。
#
# 出す答えは 2 つ:
#
#   1. `bench/binary_size/` の既存ケースセット (#1056) を両レーンで測った絶対サイズ
#   2. 合成ソースを N コピーに増やしたときの**傾き**と、linear/gc の交点
#
# (2) が要るのは、この 2 レーンの差が固定費と限界費用に分かれるからで、
# 単一サイズの比較は「gc は 5 倍でかい」とも「gc の方が小さい」とも読めて
# しまう。傾きを取って初めてどちらの領域にいるのかが決まる。
#
# ケースセットを `bench/binary_size/` と共有しているのは、`scripts/bench_binary_size.sh`
# (linear の継続的な回帰シグナル) とここの数字が同じ土俵に乗るようにするため。
# あちらが「時間方向の回帰」、ここが「レーン間の比較」で、ソースは 1 つ。
#
# 使い方:
#   bash scripts/measure_backend_code_size.sh [stage2.wasm]
#   MEASURE_SCALES="10 20 40 80" bash scripts/measure_backend_code_size.sh
#   MEASURE_FS_COMPILE=1 bash scripts/measure_backend_code_size.sh
#
# stage2 を省略した場合は最新の generations stage2 → _build/_unit_test_gen →
# seed の順で探す。
#
# Filesystem module loading and codegen are orthogonal (#2376). The default
# keeps direct compilation so this script reproduces the committed historical
# table. MEASURE_FS_COMPILE=1 resolves the same filesystem module graph for
# both lanes, while VIBE_BACKEND still selects only the final lowering. The
# committed cases are import-free to isolate the codegen slope, not because
# the gc lane is limited to a single source file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

STAGE2="${1:-}"
if [ -z "$STAGE2" ]; then
  STAGE2="$(ls -1t _build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$STAGE2" ] || STAGE2="$(ls -1t _build/_unit_test_gen/stage2.wasm 2>/dev/null | head -1 || true)"
[ -n "$STAGE2" ] || STAGE2="bootstrap/seed/compiler.wasm"
if [ ! -s "$STAGE2" ]; then
  echo "measure_backend_code_size: no compiler wasm found (tried generations / _unit_test_gen / seed)" >&2
  exit 2
fi
echo "compiler: $STAGE2"
echo "commit:   $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo

WORK="${MEASURE_WORKDIR:-_build/backend_code_size}"
rm -rf "$WORK"; mkdir -p "$WORK"

# entry 名は gc レーンが受け付けるものにする。`__no_entry__` (doctest 等が使う
# sentinel) は linear では通るが gc では "entry function not found" で落ちる。
# `main` は compiler_gate.sh 40h と bench_binary_size.sh の両方が使っている形。
#
# レーンを決める変数は**呼び出し元の環境から継承させず、両レーンで明示的に**
# 与える。継承すると測定が黙って壊れる: `VIBE_BACKEND=gc` が export されていれば
# linear のつもりの呼び出しも gc になる。両方が「同じレーンを 2 回測る」結果に
# なり、傾き 0・交点なしという無意味な答えを green のまま返してしまう。
compile_one() { # <lane> <src> <out>
  local lane="$1" src="$2" out="$3" backend=linear
  local -a module_env=(-u VIBE_FS_COMPILE)
  [ "$lane" = "gc" ] && backend=gc
  [ "${MEASURE_FS_COMPILE:-0}" = "1" ] && module_env=(VIBE_FS_COMPILE=1)
  env "${module_env[@]}" VIBE_BACKEND="$backend" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" "$src" "$out" main >/dev/null 2>&1 || true
}

# 実行も同様に、レーン変数を落としてから測る (生成済み wasm の実行には効かない
# はずだが、"効かないはず" は測定コードが依拠してよい性質ではない)。
run_lane() { # <wasm> <stdout-file>
  env -u VIBE_FS_COMPILE -u VIBE_BACKEND VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash scripts/run_wasm_vibe_host_runner.sh "$1" >"$2" 2>&1 || true
}

fail=0

measure() { # <label> <src>
  local label="$1" src="$2" l g verdict
  compile_one linear "$src" "$WORK/$label.lin.wasm"
  compile_one gc "$src" "$WORK/$label.gc.wasm"
  l=$(stat -c%s "$WORK/$label.lin.wasm" 2>/dev/null || echo 0)
  g=$(stat -c%s "$WORK/$label.gc.wasm" 2>/dev/null || echo 0)
  # 0 バイトは「小さい」ではなく「コンパイルに失敗した」である。握り潰すと
  # gc レーンの無意味な勝利になるので、サイズ表に混ぜずに失敗として報告する。
  if [ "$l" -eq 0 ] || [ "$g" -eq 0 ]; then
    printf '%-18s %10s %10s   COMPILE FAILED: %s\n' "$label" "$l" "$g" \
      "$(head -c 140 "$WORK/$label.gc.wasm.diag" 2>/dev/null || head -c 140 "$WORK/$label.lin.wasm.diag" 2>/dev/null)"
    fail=1
    return
  fi
  # 両レーンの出力がバイト単位で同一なら、それは「差が無い」ではなく
  # **同じレーンを 2 回測った**である (compile_one の注記を参照)。gc の無条件
  # プレリュードだけで 4 KB 違うので、正常に測れていれば一致はしない。
  if cmp -s "$WORK/$label.lin.wasm" "$WORK/$label.gc.wasm"; then
    printf '%-18s %10s %10s   IDENTICAL OUTPUT: both lanes produced the same bytes -- backend selection did not take effect\n' \
      "$label" "$l" "$g"
    fail=1
    return
  fi
  # サイズだけ比べても意味がないので、両レーンが同じ挙動をすることも見る。
  # 片方が壊れた wasm を出していたら小さくて当たり前になる。比較は
  # **stdout 全体**で行う: `tail -1` はランナーが最後に付ける戻り値だけを残し、
  # `hello_world` の "Hello, world!" や `fizzbuzz` の 100 行を捨ててしまうので、
  # 出力が壊れているレーンを "一致" と報告してしまう。
  run_lane "$WORK/$label.lin.wasm" "$WORK/$label.lin.out"
  run_lane "$WORK/$label.gc.wasm" "$WORK/$label.gc.out"
  if cmp -s "$WORK/$label.lin.out" "$WORK/$label.gc.out"; then
    # 表に出すのは戻り値 (最終行) だけ。判定は全出力で済ませてある。
    verdict="=$(tail -1 "$WORK/$label.lin.out")"
  else
    verdict="DISAGREE (see $WORK/$label.{lin,gc}.out)"
    fail=1
  fi
  printf '%-18s %10s %10s %8s%%  %s\n' "$label" "$l" "$g" \
    "$(awk -v a="$l" -v b="$g" 'BEGIN{printf "%+.1f", (b-a)*100/a}')" "$verdict"
  echo "$label $l $g" >> "$WORK/raw.txt"
}

# 傾きを測るための合成ソース。1 コピーが struct 定義 + 射影 + 配列確保ループ +
# 文字列構築を 1 セット持つ。既存ケースセットは固定サイズなので傾きが取れず、
# 交点 (この測定の主結論) はこちらでしか出せない。
gen_scaled() { # <n> <out>
  local n="$1" out="$2" k body=""
  {
    echo 'fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }'
    for ((k = 0; k < n; k++)); do
      cat <<EOF
struct P$k { x: Int; y: Int }
fn mk$k(n: Int) -> P$k { P$k::{ x: n + $k, y: n * 2 } }
fn sum$k(p: P$k) -> Int { p.x + p.y }
fn build$k(n: Int) -> Array[Int] {
  let b = ArrayBuilder::new()
  let mut i = 0
  while i < n { ArrayBuilder::push(b, sum$k(mk$k(i))); i = i + 1 }
  ArrayBuilder::freeze(b)
}
fn join$k(n: Int) -> String {
  let b = StringBuilder::new()
  let mut i = 0
  while i < n { StringBuilder::push(b, "x"); i = i + 1 }
  StringBuilder::freeze(b)
}
EOF
    done
    for ((k = 0; k < n; k++)); do
      [ -n "$body" ] && body="$body + "
      body="${body}Array::length(build$k(3)) + String::length(join$k(2))"
    done
    echo "let main = () -> Int { fib(10) + $body }"
  } > "$out"
}

printf '%-18s %10s %10s %9s  %s\n' program linear wasm-gc delta result

# 固定費そのものを測る対照。既存ケースセットの最小 (hello_world) すら println を
# 呼ぶので、「何も使わないプログラム」は別に用意しないと取れない。
cat > "$WORK/empty.vibe" <<'EOF'
let main = () -> Int { 0 }
EOF
measure empty "$WORK/empty.vibe"

for src in bench/binary_size/*.vibe; do
  measure "$(basename "$src" .vibe)" "$src"
done

SCALES="${MEASURE_SCALES:-10 40 80 160}"
for n in $SCALES; do
  gen_scaled "$n" "$WORK/scaled$n.vibe"
  measure "scaled$n" "$WORK/scaled$n.vibe"
done

# 交点は最小と最大のスケール点を通る直線で出す。中間点はその直線に乗るかの
# 確認用で、乗らなければ線形近似そのものが誤りなので残差を報告する。
echo
if [ ! -s "$WORK/raw.txt" ]; then
  echo "slope: no usable measurements -- every case failed above"
  exit 1
fi
awk '
  /^scaled/ {
    n = substr($1, 7) + 0; lin[n] = $2; gcv[n] = $3
    ns[++cnt] = n; if (!lo || n < lo) lo = n; if (n > hi) hi = n
  }
  END {
    if (!lo || lo == hi) { print "slope: need at least two scale points"; exit }
    sl = (lin[hi] - lin[lo]) / (hi - lo); sg = (gcv[hi] - gcv[lo]) / (hi - lo)
    il = lin[lo] - sl * lo; ig = gcv[lo] - sg * lo
    printf "slope:     linear %.1f B/copy, wasm-gc %.1f B/copy (gc = %.1f%% of linear)\n", sl, sg, sg * 100 / sl
    printf "intercept: linear %.0f B, wasm-gc %.0f B (fitted, NOT the empty-program size)\n", il, ig
    worst = 0
    for (i = 1; i <= cnt; i++) {
      n = ns[i]
      dl = lin[n] - (il + sl * n); dg = gcv[n] - (ig + sg * n)
      if (dl < 0) dl = -dl; if (dg < 0) dg = -dg
      if (dl > worst) worst = dl; if (dg > worst) worst = dg
    }
    printf "residual:  max %.0f B off the fitted line (%.1f%% of the largest point)\n", worst, worst * 100 / lin[hi]
    if (sl <= sg) { print "crossover: none -- wasm-gc grows at least as fast as linear"; exit }
    c = (ig - il) / (sl - sg)
    printf "crossover: %.0f copies == %.1f KB of linear output\n", c, (il + sl * c) / 1024
  }
' "$WORK/raw.txt"

if [ "$fail" -ne 0 ]; then
  echo "measure_backend_code_size: FAILED (see rows above)" >&2
  exit 1
fi
