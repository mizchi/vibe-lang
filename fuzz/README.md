# fuzz — selfhost compiler differential fuzzing

生成型の差分ファジングで compiler のバグ(miscompile / crash / hang /
backend・lane 間 divergence)を洗い出すハーネス。#722(struct field の
型盲目 first-match 解決)級のバグを、修正前 compiler に対して 8 seeds 中
2 件 MISMATCH として自動検出できることを確認済み。

## 使い方

```bash
# 生成型差分モード(default): seed A..B
bash fuzz/run_fuzz.sh --seeds 1..300

# parser 頑健性(byte mutation)モード: diag 以外の落ち方(trap/hang)だけが finding
bash fuzz/run_fuzz.sh --mutate --seeds 1..300

# CLI (stage2) を明示指定(default: 最新 generation の stage2.wasm)
bash fuzz/run_fuzz.sh --seeds 1..50 --cli _build/selfhost/generations/<gen>/stage2.wasm
```

findings は `_build/fuzz/findings/seed_<seed>_<class>/`(入力 + ログ +
note.txt)に保存され、`_build/fuzz/failing_seeds.txt` に一覧が残る。
seed 決定論なので `python3 fuzz/gen_program.py <seed> <dir>` で再生成できる。

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

## 生成器の設計(fuzz/gen_program.py)

- **trap-free by construction**: 全算術を `& 1048575` でマスク(小さく
  非負に保つ)、除数は `1 + (e & 15)`、shift 量は `& 15`、配列 index は
  マスク済み非負値の `% len`、loop はリテラル上限。よって実行時 trap は
  すべて compiler バグ。
- **既知バグクラスを意図的に高頻度で生成**: 同名 field を異 slot に持つ
  struct 群(#722)、literal 順 ≠ 宣言順の struct 構築、`mut` field への
  store、Option[Struct] を関数境界越しに返して field 読み、mut capture
  closure、for-in 内包(#538)、enum 網羅 match、文字列補間、tuple 射影、
  guarded div/mod。
- 期待値 oracle は持たない(差分のみ)。生成器と compiler の意味論の
  二重実装ズレで偽陽性を出さないため。

## 制約 / 今後

- effect(Error 以外)、Map、Bytes、Double、trait/generic は未生成
  (gc lane の対応範囲と偽陽性回避を優先した v1 サブセット)。広げる
  ときは gc 非対応機能を lane 別に skip する仕組みを足す。
- 最小化は手動(seed を控えて手で削る)。自動 shrink は future work。
- 実測スループット: 生成モード ~3.5s/seed(コンパイル 4 + 実行 4)、
  mutation モード ~1s/seed。
