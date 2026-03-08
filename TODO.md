# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Self-host Compiler (`vibe/compiler/`)

### MoonBit → vibe 完全置換の機能差分

**現状**: T1–T20 全完了 (318+ tests)。ポータブルな MoonBit テスト移植も完了。
**残**: MoonBit 固有機能（ScopedRef, API versioning, vibe shell desugar 等）は selfhost 対象外。

### Language/Stdlib Proposals (AI-first authoring)

- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Self-Host WASM Codegen (vibe/compiler/ で .vibe → .wasm)

**目標**: selfhost コンパイラが自身を WASM にコンパイルできる真の完全セルフホスト
**現状**: ライブラリ層は完成（lex/parse/check/codegen）。API 公開 + CLI が未実装。

### P5: Meta-circular Self-Hosting

**ゴール**: `selfhost.wasm` が .vibe ソースを受け取り .wasm を出力する

#### S1: index.vibe API 拡張 — checker/codegen を export ✅
- [x] checker API を export: `check_program`, `check_program_with_env`, `check_stmts`
- [x] codegen API を export: `compile_module`, `compile_wasi_module`, `compile_wasi_module_gc`
- [x] Type, TypeEnv を export

#### S2: compiler.vibe — 統合コンパイルパイプライン ✅
- [x] `compile_source(source: String) -> Bytes` 関数（lex → parse → check → codegen 一気通貫）
- [x] `compile_source_wasi(source, entry_name) -> Bytes` 関数（WASI エントリ付き）
- [x] テスト: `compiler_test.vibe` (6 tests) — int/fn/if/enum/while/wasi

#### S3: cli.vibe — 最小 CLI エントリポイント
- [ ] argv 相当のコマンドライン引数取得（WASI or builtin）
- [ ] `fs_read_file` でソース読み込み → `compile_source` → `fs_write_bytes` で .wasm 出力
- [ ] `vibe compile <input.vibe> -o <output.wasm>` 相当の最小 CLI
- [ ] テスト: CLI が実際にファイルを読み書きして .wasm を生成

#### S4: module loader — import 解決
- [ ] `SImport` から依存ファイルパスを抽出
- [ ] 依存グラフのトポロジカルソート
- [ ] cross-module TypeEnv 伝播（import 先の型を caller に反映）
- [ ] テスト: 複数ファイルの import 解決 → 結合コンパイル

#### S5: meta-circular milestone
- [ ] selfhost.wasm が自身のソース (vibe/compiler/*.vibe) をコンパイルして .wasm を出力
- [ ] stage1 (host compile) と stage2 (selfhost compile) の出力が一致
- [ ] CI gate: bootstrap gate に S5 を追加

### P4: セルフコンパイル + Component Model (完了分)

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
