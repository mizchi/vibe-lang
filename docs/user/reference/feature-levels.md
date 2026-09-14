# wasm 対応水準の分離と検証 (build levels)

更新日: 2026-08-15

## 背景

vibe には wasm proposal への依存が 2 系統ある:

1. **compiler 自身の実行基盤** (`runtime/viberun`, wasmtime embedding)。
   `Config::wasm_function_references(true)` / `wasm_gc(true)` /
   `wasm_exceptions(true)` / `wasm_simd(true)` / `wasm_relaxed_simd(true)` /
   `wasm_tail_call(true)` を明示的に有効化しており (`runtime/viberun/src/main.rs`)、
   experimental proposal + flag に依存してよい。ここは vibe を動かす側の
   環境なので、利用者の実行環境の広さとは無関係。
2. **compiler が生成する wasm** (`vibe build` の出力)。これは利用者が
   Chrome / Node.js / Deno / Firefox / Safari 等、任意の wasm 実行環境で
   動かす前提であり、flag なしで動く proposal だけに依存すべき。

この2つを混同すると、「viberun では動くが生成コードとしては尚早な proposal」
を無自覚に codegen へ持ち込むリスクがある。本ドキュメントはこの2水準を
分離し、実際にどの proposal を使っているかを追跡可能にする。

## マスターデータ

`https://webassembly.org/features/` は HTML ページであり、直接スクレイプ
すべき対象ではない。裏にあるマスターデータは
[`WebAssembly/website` リポジトリの `features.json`](https://github.com/WebAssembly/website/blob/main/features.json)
で、エンジンごとの対応バージョン/flag要否がここに構造化されている。

- 取得: `bash scripts/wasm_feature_matrix_fetch.sh` → `docs/wasm/feature-matrix.json` を上書き取得
- 分類/検証: `bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex`

vendored snapshot (`docs/wasm/feature-matrix.json`) を repo にコミットして
おき、fetch は明示的に実行したときだけ更新する（gate をネットワーク依存に
しない）。

## Build level の定義

`scripts/wasm_feature_levels.vibex` の `engine_sets()`:

| level | engines | 意図 |
|---|---|---|
| `v8` | Chrome, Node.js, Deno | 「chrome, v8, deno, node」の文字通りの解釈。3つとも V8 系だが、バンドルされる V8 のリリース cadence が違うため個別に見る価値がある |
| `web-baseline` | 上記 + Firefox, Safari | V8 系以外のエンジンへの移植性まで見込む、より保守的な水準 |

ある proposal がある level で "safe" と判定されるのは、その level の全
engine が **flag なしで** サポートしている場合のみ (`null`/`false`/
`["flag", ...]` はどれも失格)。

compiler-host 水準は engine set を使わず、`Wasmtime` 単独行を単に記録する
だけ（許可判定はしない — viberun は明示的に選んで experimental flag を
有効化しているので、ここで縛る意味がない）。

## 現状: vibe codegen が実際に使っている proposal

`scripts/wasm_feature_levels.vibex` の `used_by_codegen()` に宣言する
（証拠はコード grep、**照合は生成された wasm バイナリに対して行う** —
下記「`--scan`」参照）:

| proposal | 使用箇所 | 条件 |
|---|---|---|
| `bulkMemory` | linear + gc backend: `memory.copy` / `memory.fill` (`codegen/common_extractors/common_extractors.vibe` の `emit_memory_copy` / `emit_memory_fill`) | builtin body 約 18 箇所 — 文字列/配列コピー、hash index table の一括ゼロ初期化 |
| `gc` | gc backend: RC cell / non-escaping local record の `struct.new/get/set`、reference lane の `array.new_default/get/set/len`、およびそれらの struct/array 型定義 (`codegen/gc/backend_body.vibe`, `codegen/gc/backend_expr.vibe`) | wasm-gc backend 選択時のみ (release 既定は linear) |
| `exceptionsFinal` | linear + gc backend: `try_table` + tag section (`codegen/wasi/linked_compile.vibe`, `codegen/gc/backend_expr.vibe`, #538/#721) | module が effect/throw を使うときだけ emit（純計算 module はゼロ） |
| `simd` | linear + gc backend: v128 opcode (`codegen/wasm_emit/simd.vibe`) | `simd_skip_ws` 等、特定 builtin 経由でのみ |
| `typedFunctionReferences` | gc backend: private callee の typed parameter/result、typed local、および reference lane join の type-index blocktype (`codegen/gc/backend_body.vibe`, `codegen/gc/backend_expr.vibe`) | wasm-gc backend で reference lane が成立するときのみ |

2026-08-15 時点のスナップショットでは、この5つはいずれも `v8` /
`web-baseline` 両水準で **safe**（`bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex`
の出力参照）。tail-call proposal (`return_call`) は compiler-host 側
(viberun) のみが有効化しており、**codegen は self-tail-call を wasm
`return_call` opcode ではなく AST レベルの while-loop 書き換えで実装して
いる** (`codegen/common_base/self_tail_call.vibe`) ため、生成 wasm 側の
tail-call proposal 依存は現状ゼロ。

## 検証

```bash
# 人間向けレポート
bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex

# 機械可読
bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex -- --json

# docs/wasm/feature-levels.expected.json との diff をチェック (nonzero exit = drift)
bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex -- --check

# マスターデータ更新後、意図した変更なら snapshot を更新
bash scripts/wasm_feature_matrix_fetch.sh
bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex -- --check   # 差分を確認してから
bash scripts/vibe_run.sh scripts/wasm_feature_levels.vibex -- --update-expected
```

`--check` は現時点で release gate (`pkf run release-check` /
`scripts/compiler_gate.sh`) には配線していない — upstream の対応状況が
変わっただけで gate が赤くなるのは早すぎる。まずは手動実行 + このドキュメント
で運用し、`USED_BY_CODEGEN` の proposal が実際に non-safe に転落した場合の
対応フローができてから gate 化を検討する。

## `--scan`: 宣言をバイナリと突き合わせる (#1133)

`used_by_codegen()` は手で書く。手で書いたものは**ずれる** — gc の参照レーンが
typed function signature を出し始めたとき、気づいたのはバイナリを手で読んだ
ときでした。`--scan` はこれをバイナリ側から検査します。

```bash
vibe run scripts/wasm_feature_levels.vibex -- --scan path/to/*.wasm
```

`@vibex/wasm_parser` の `scan_features_checked` が、型セクション・セクションの
有無・**命令列の走査**から proposal を導き、`used_by_codegen()` と照合します。
命令は「バイト列を prefix で grep する」のではなく `next_instruction` で
**1 命令ずつ歩いて**判定します — 素朴な走査は opcode と、たまたま同じ値を持つ
即値を区別できないので、使っていない proposal を報告してしまう。宣言と
突き合わせる道具としては、それは不完全であるより悪い。

判定は**非対称**で、そこが要点です:

| | 扱い |
|---|---|
| 出しているのに宣言に無い | **fail**。docs から選んだターゲットが生成 wasm を拒否しうる |
| 宣言にあるのに出ていない | 報告のみ。その corpus に該当する入力が無いだけかもしれない |

**走査が最後まで届かなかったモジュールは比較しません。** 得られた feature は
真の部分集合なので、宣言と比べると「宣言が多すぎる」と読めてしまう —
結論が逆になります。何も言わない方が正直です。

`pkf run test-wasm-validate-parity` から
`scripts/test_wasm_validate_parity.sh` 経由で走ります（fixture のコンパイルが
高コストなので、validator の parity 測定と corpus を共有しています）。

初回実行で **`bulkMemory` が出ているのに宣言に無い**ことを検出しました
(`memory.copy` / `memory.fill`、builtin body 約 18 箇所)。両 engine set で
supported なので移植性の実害はありませんでしたが、宣言がバイナリを説明して
いなかったのは事実です。

### 残っているもの

- `memory64` の i64 addressing は未判定 (このコンパイラは出していない)
- `0xFE` (atomics) は `next_instruction` が未対応なので、使い始めたら
  「走査が届かない」側に落ちる — 黙って見落とすのではなく skip として出る
