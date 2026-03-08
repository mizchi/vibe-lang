# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Self-host Compiler (`vibe/compiler/`)

### Compiler Review Backlog (readability + selfhost robustness)

- [x] refactor: `compile_expr` の責務分割（`compile_call` / `compile_match` / `compile_lambda`）
  - CompileCtx/CompileCtxGc struct 導入でパラメータ 25→6 に削減
  - `compile_call`, `compile_match`, `compile_lambda` を両バックエンドで抽出
  - `with { Error }` 付き関数型パラメータで再帰コールバックを渡す設計

### Language/Stdlib Proposals (AI-first authoring)

- [x] language: variant の安定 ID（型ID + ctorID）を IR/実行時で保持
  - タグ計算: `(type_index << 16) | variant_index` — 型ごとに安定、宣言順非依存
  - CtorTable に `type_names` 追加 — 各コンストラクタの所属型を記録
  - 今後: lookup_ctor の型名フィルタ、同名コンストラクタ対応
- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Self-Host WASM Codegen (vibe/compiler/ で .vibe → .wasm)

**目標**: selfhost コンパイラが自身を WASM にコンパイルできる真の完全セルフホスト

### P4: セルフコンパイル + Component Model

- [x] selfhost の lexer.vibe が .wasm にコンパイルされ wasmtime で実行可能
- [x] selfhost compiler 全体 (vibe/compiler/) が .wasm にコンパイルされ実行可能
- [x] component_codegen を .vibe で再実装（core wasm → component binary wrap）
- [ ] mwac plug 相当を .vibe で実装 or builtin 化（adapter compose）
- [ ] milestone: selfhost compiler 全体が .wasm component として動作

### 現在の .vibe 言語の制約と回避策

| 制約 | 影響 | 回避策 |
|------|------|--------|
| `~` (bit_not) 非対応 | ビット反転 | `x ^ 0x7FFFFFFFFFFFFFFF` で代用 |
| mutable closure 制限 | CodegenCtx 的な状態管理 | レコード + 関数引数で明示受け渡し |
| mwac/wite は MBT パッケージ | .vibe から直呼び不可 | P4 で対応 |

## WASM HTTP P3 Implementation

**Phase 3 残タスク**:
- [ ] `wasi:http/handler` interface export を codegen で直接生成（resource/stream 対応が必要、将来課題）

## Blocked / External

- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応

## Deferred

- [ ] `wasi:http/handler` interface export を codegen で直接生成（P4 の先、resource/stream/future 40+ 型）
