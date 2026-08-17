# fuzz — selfhost compiler differential fuzzing

Source lives at `tests/fuzz/`; generated work/findings stay in `_build/fuzz/`.

生成型の差分ファジングで compiler のバグ(miscompile / crash / hang /
backend・lane 間 divergence)を洗い出すハーネス。#722(struct field の
型盲目 first-match 解決)級のバグを、修正前 compiler に対して 8 seeds 中
2 件 MISMATCH として自動検出できることを確認済み。

#765 で liveness-aware 生成(下記)と自動 reducer を追加。2026-07-07 時点の
HEAD に対して liveness-aware 生成(default/`--liveness-bias 0.85`/
`--liveness-bias 0.95` の混在、seeds 1..1300 相当)で約 1900 差分 seeds +
`--classic` 50 seeds + `--mutate` 200 seeds を流し、finding 0 件
(#725/#737/#745 が既に修正済みであることと整合)。今後この生成モードを
継続的に回す際の参照値として記録。

## 使い方

```bash
# 生成型差分モード(default): seed A..B。liveness-aware bias は default で有効
bash tests/fuzz/run_fuzz.sh --seeds 1..300

# 旧来の生成のみ(liveness-aware bias を無効化、#765 前の挙動)
bash tests/fuzz/run_fuzz.sh --classic --seeds 1..300

# liveness-aware bias を明示指定(0.0..1.0、テスト用。--classic と併用不可)
bash tests/fuzz/run_fuzz.sh --liveness-bias 0.85 --seeds 1..300

# parser 頑健性(byte mutation)モード: diag 以外の落ち方(trap/hang)だけが finding
bash tests/fuzz/run_fuzz.sh --mutate --seeds 1..300

# CLI (stage2) を明示指定(default: 最新 generation の stage2.wasm)
bash tests/fuzz/run_fuzz.sh --seeds 1..50 --cli _build/selfhost/generations/<gen>/stage2.wasm
```

findings は `_build/fuzz/findings/seed_<seed>_<class>/`(入力 + ログ +
note.txt)に保存され、`_build/fuzz/failing_seeds.txt` に一覧が残る。
seed 決定論なので `python3 tests/fuzz/gen_program.py <seed> <dir>` で再生成できる
(liveness bias 込み。`--classic` で bias 無効、`--liveness-bias=X` で明示指定)。

見つけた finding は `tests/fuzz/reduce.py` で自動最小化できる(下記)。

## 何を比較するか(oracle)

1 seed から同一プログラムを 4 通りでコンパイル・実行し、**結果が全一致**
することを要求する:

| lane | コンパイル | 実行 |
| ---- | --------- | ---- |
| bump | `VIBE_RC=0` | node host runner |
| RC   | `VIBE_RC=1`(production default) | node host runner |
| gc   | `VIBE_BACKEND=gc` | `wasmtime -W gc=y,function-references=y,exceptions=y` |
| FS-linked | 分割版(defs.vibe + main.vibe)を `VIBE_FS_COMPILE=1` | node host runner |

加えて: 生成プログラムは well-typed なので **diag が出たら finding**
(COMPILE_DIAG)。コンパイル/実行の trap(COMPILE_CRASH / RUN_TRAP)、
timeout(COMPILE_HANG / RUN_HANG)、lane 間の結果不一致(MISMATCH)も
finding。

## 生成器の設計(tests/fuzz/gen_program.py)

- **trap-free by construction**: 全算術を `& 1048575` でマスク(小さく
  非負に保つ)、除数は `1 + (e & 15)`、shift 量は `& 15`、配列 index は
  マスク済み非負値の `% len`、loop はリテラル上限。よって実行時 trap は
  すべて compiler バグ。
- **既知バグクラスを意図的に高頻度で生成**: 同名 field を異 slot に持つ
  struct 群(#722)、literal 順 ≠ 宣言順の struct 構築、`mut` field への
  store、Option[Struct] を関数境界越しに返して field 読み、mut capture
  closure、for-in 内包(#538)、enum 網羅 match、文字列補間、tuple 射影、
  guarded div/mod。
- **liveness-aware bias(#765、default 有効)**: CLIR 論文(arXiv
  2606.26977)の liveness 駆動生成を移植。`Gen.liveness_bias` は seed ごと
  に `0.12..0.55` からドロー(`--classic` で 0、`--liveness-bias=X` で
  明示指定)し、`gen_stmts` の各文生成をこの確率で以下 4 パターンの
  どれかに差し替える(既存の生成メニューを置き換えるのではなく、
  その手前に確率的なバイパスとして追加。既存カバレッジは失われない):
  - `gen_def_use_chain`: 早期に作った値(struct または Int)を 3〜6段の
    中間 let-binding / helper 呼び出しで素通しし、末尾の sink(acc への
    fold、または struct-consuming helper 呼び出し)でだけ消費する。
    dup/drop 会計が長い生存区間で壊れていないかを突く。
  - `gen_alias_stmts`: `let b = a` の後、`a` と `b` の両方を使う。
    alias 生成時の RC dup が正しいか(両方が独立に drop 可能か)を突く。
  - `gen_conditional_move`: `if` の片方の branch だけが値を(struct
    を引数で渡す = move する)helper 呼び出しで消費し、もう片方は
    一切触らない。触らなかった branch が正しく drop するか、`if` の
    外側スコープでの後続使用が壊れないかを突く。
  - `gen_cross_scope_capture`: `if` の branch 内(ネストした式スコープ)
    で定義したクロージャが外側スコープの `let` 束縛(struct)または
    `mut` 変数を capture し、`if` が解決した後の外側スコープで呼ばれる。
    capture 時の dup 会計を突く。
  - **tail-resume 近似**(#737 の軽量版、effect handler 不要):
    `gen_helpers` が `carry_walkN(n: Int, carried: Sx) -> Int` という
    再帰関数(`fn` 構文、self-recursion に `rec` 不要)を生成し、
    `carried` を各フレームで一切触らずに素通しして base case(`n<=0`)
    でだけ消費する。呼び出し深さは `gen_main` 側で常にリテラル
    (5..15)に固定し、生成された乱数を再帰深さに使わない(無限再帰 /
    hang を作らないための構造的ガード)。
- 期待値 oracle は持たない(差分のみ)。生成器と compiler の意味論の
  二重実装ズレで偽陽性を出さないため。

## 自動 test-case reducer(tests/fuzz/reduce.py, #765)

MISMATCH/trap/diag 等の finding を、**同じ finding class を保ったまま**
自動最小化する delta-debugging ツール(CLIR 論文の「診断駆動の階層的
test-case reduction / semantic substitution」の移植)。

```bash
# seed から直接: 失敗した seed を再生成して最小化
python3 tests/fuzz/reduce.py 217 --class MISMATCH

# 既存の finding ファイルから
python3 tests/fuzz/reduce.py _build/fuzz/findings/seed_217_MISMATCH/single.vibe \
  --class MISMATCH --cli _build/selfhost/generations/<gen>/stage2.wasm
```

- oracle は `tests/fuzz/classify.sh`(`tests/fuzz/lib_oracle.sh` 経由で
  `run_fuzz.sh` と完全に同じ compile/run/finding-class 判定ロジックを
  共有)。「class が同じか」だけを見るので、finding class は
  `--class` で指定する(`MISMATCH` / `COMPILE_CRASH` / `COMPILE_HANG` /
  `RUN_TRAP` / `RUN_HANG` / `COMPILE_DIAG`)。
- 2 段階の縮約: ① brace-depth ベースの再帰的 ddmin(トップレベル宣言 →
  文 → ネストした if/closure/while body、の順に段階的に細かく削る)、
  ② 式→定数の semantic substitution(`let x = EXPR` の RHS を
  `0`/`1`/`""`/`false`/`true` に置換、整数リテラルを縮小)。どちらも
  「置換後も同じ class が再現するか」を毎回 oracle で確認し、再現する
  場合だけ採用する。
- FS-linked lane(defs.vibe+main.vibe)は縮約対象外(single.vibe だけを
  bump/RC/gc の 3 lane で判定)。FS lane 固有の finding は手動で
  defs.vibe/main.vibe に縮約後の宣言を移す。
- `COMPILE_DIAG` の縮約は class が粗い(「診断が出たか」しか見ない)
  ため、縮約後に実際の診断メッセージが元の finding と同じ問題を指して
  いるか目視確認すること。
- 出力は既定で `_build/fuzz/reduced/<name>_<class>.vibe`(`--out` で
  上書き可)。`--budget` で oracle 呼び出し回数の上限を設定できる
  (デフォルト 4000、1 回あたり compile×3 + run×3 程度)。

## 制約 / 今後

- effect(Error 以外)、Map、Bytes、Double、trait/generic は未生成
  (gc lane の対応範囲と偽陽性回避を優先した v1 サブセット)。広げる
  ときは gc 非対応機能を lane 別に skip する仕組みを足す。
- 実測スループット: 生成モード ~1.2〜1.3s/seed(コンパイル 4 + 実行 4、
  キャッシュ次第でこれより速いこともある)、mutation モード
  ~0.15s/seed。reduce.py は 1 finding あたり数秒〜数分(縮約の深さと
  budget 次第)。
