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

`scripts/wasm_feature_levels.vibex` の `used_by_codegen()` に手動でキュレーション
（コード grep による証拠ベース、**wasm バイナリの opcode 走査による検証では
ない** — 下記「未実装のスコープ」参照）:

| proposal | 使用箇所 | 条件 |
|---|---|---|
| `gc` | gc backend: RC cell / non-escaping local record の `struct.new/get/set`、reference lane の `array.new_default/get/set/len`、およびそれらの struct/array 型定義 (`codegen/gc/backend_body.vibe`, `codegen/gc/backend_expr.vibe`) | wasm-gc backend 選択時のみ (release 既定は linear) |
| `exceptionsFinal` | linear + gc backend: `try_table` + tag section (`codegen/wasi/linked_compile.vibe`, `codegen/gc/backend_expr.vibe`, #538/#721) | module が effect/throw を使うときだけ emit（純計算 module はゼロ） |
| `simd` | linear + gc backend: v128 opcode (`codegen/wasm_emit/simd.vibe`) | `simd_skip_ws` 等、特定 builtin 経由でのみ |
| `typedFunctionReferences` | gc backend: private callee の typed parameter/result、typed local、および reference lane join の type-index blocktype (`codegen/gc/backend_body.vibe`, `codegen/gc/backend_expr.vibe`) | wasm-gc backend で reference lane が成立するときのみ |

2026-08-15 時点のスナップショットでは、この4つはいずれも `v8` /
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

## 未実装のスコープ (フォローアップ)

`USED_BY_CODEGEN` は **ソースコードの grep による手動キュレーション**であり、
実際に出力された `.wasm` バイナリの opcode を静的に走査して自動検出した
ものではない。真の enforcement (「宣言した level を超える proposal を
codegen が使ったら fail する」) には wasm バイナリのセクション/opcode
パーサが要る。スコープが大きいため本パスでは見送り、追跡 issue を切った: #1133。
