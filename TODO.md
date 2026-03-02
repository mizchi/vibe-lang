# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Playground

- [ ] CodeMirror 等のエディタ統合（シンタックスハイライト、補完）
- [ ] 複数スニペットのプリセット / URL 共有

## Self-host Compiler (`vibe/compiler/`)

- [x] Self-hosting: vibe/compiler が vibe/compiler 自身を parse + eval する（最終ゲート）
  - selfhost lexer が token.vibe をトークナイズ（自身のソースを `fs_read_file` で読み込み）
  - selfhost parser + printer が token.vibe を roundtrip（lex → parse → print）
  - selfhost evaluator が token.vibe を lex → parse → eval し、`token_to_string(TInt(42))` を呼び出して正しい結果を返す
  - DoD 達成: meta-circular self-hosting 完了
- [x] Gate 0: selfhost smoke suite を安定通過
  - `eval_selfhost_test.vibe`
  - `eval_selfhost2_test.vibe`
  - `eval_selfhost3_test.vibe`
- [x] Gate 1: 実行制御の整合（ループ制御を実運用可能にする）
  - `break` / `continue` の parser/checker/eval を end-to-end で一致
  - `return` の仕様を確定し、未対応なら明示的に構文拒否を固定
  - DoD: ループ制御の fixture/e2e を追加して green
- [x] Gate 2: 構文と実行系のギャップを解消
  - postfix `arr[i]` は selfhost で未使用（`array_get` 使用）、`t.0`/`r.field` は EDot で動作済み → 対応不要
  - `do`/`loop`/`yield`/`declare` に明示的拒否メッセージ追加（`raise`/`return` と同様）
  - DoD: `vibe/compiler` ソースで使う構文が parse/eval 双方で未接続なし
- [x] Gate 3: 型契約を自己適用レベルに引き上げる
  - 型注釈の契約層を実装に一致させる (`TyApp` / `TyFn` / `TyTuple` を `CtUnknown` に落とさない)
  - builtins の型契約と evaluator 実装の差分を解消する（型のみ存在/実装のみ存在の不一致）
  - DoD: selfhost で使う主要 builtins の型/実装差分が 0
- [x] Gate 4: 依存計算と incremental checker を本線化
  - incremental 型検査DBを checker パスへ統合（`type_db.vibe` + `RippleDb` + `TypeEnv` キャッシュ）
  - AST ベース依存抽出（`collect_import_deps`）、ripple 一本化、path 解決統合
  - DoD 達成: cold/warm 型検査結果一致、差分更新のみ再計算（テスト・ベンチマーク検証済み）
- [x] Gate 5: full self-host e2e
  - `vibe/compiler` 一式を `parse + eval` して主要ワークフローを実行可能にする
  - DoD 達成: selfhost 用トップレベル e2e（実ソース入力）を CI で常時 green
  - テスト 4 件: token enum import、lex→tokens、lex→parse→print roundtrip、meta-circular eval pipeline

## Self-host Parity: MoonBit 実装と結果一致

目標: selfhost compiler (vibe/compiler/) の lex → parse → print roundtrip が全 compiler ソースで MoonBit ホスト実装と一致すること。

**現状 (18 ファイル中 16 OK / 2 除外):**

| 状態 | ファイル |
|------|---------|
| OK | eval_e2e_helpers, index, checker_resolve, ast, eval_loader, checker_stmt, values, token, eval_stmt, type_db, checker, printer, builtins, eval_builtins, lexer, types |
| 除外 | parser.vibe (1608行), eval.vibe (1354行) — インタプリタでの eval が大きすぎ OOM |

**修正済みエラーパターン:**

- [x] P1: printer の文字列エスケープ — `escape_string` ヘルパー追加（`\"` `\\` `\n` `\t` `\r` `\0`）
- [x] P2: lexer のシングルクォート対応 — `lex_char` 関数追加（`'a'` → `TInt(97)`）
- [x] P3: printer の ELet/ESeq ブレース囲み — `ELet`, `ELetRec`, `ELetMut`, `EAssign`, `EAssignOp`, `ESeq` を `{ }` で出力
- [x] P4: parser のブロック内暗黙シーケンス — `parse_block_after_expr` の `_` ケースで mode 20 継続
- [x] P5: import パス内キーワードトークン — `TModule`, `TType`, `TMatch`, `TTest` を `collect_import_path` に追加
- [x] P6: if-without-else 対応 — parser: `EIf(cond, then, EUnit)` 返却、printer: else 省略

**残タスク:**

- [ ] parser.vibe / eval.vibe の roundtrip 対応（インタプリタ性能 or ネイティブテストが必要）

## Language Features

- [ ] Multi-language frontend adapters:
  tree-sitter-based extractor を baseline とし、optional semantic providers (compiler/LSP) で type-resolution gaps を補完。
  `vibe ide`/`vibe lsif` は shared backend API 上に維持。

## Bundle Size (In Progress)

目標: importer-level DCE で主要 std モジュールのサイズ最適化。

**Importers (wasm with DCE, 2026-03-01):**

| file | bytes |
|------|-------|
| consumer_option_core | 1028 |
| consumer_option_extra | 1558 |
| consumer_double_core | 1764 |
| consumer_double_rounding | 4877 |

ベンチ: `scripts/bench_bundle_size.sh`, `bench/bundle_size/cases.txt`

## Blocked / External

- [ ] WASM HTTP builtins: 現在 `unreachable` trap。WASI P3 HTTP (`wasi:http@0.3.0-draft`) 安定待ち
  - Client: `wasi:http/handler.handle` で outgoing-request 送信
  - Server: `wasi:http/handler` export で incoming-request 受信 (wasmtime serve)
- [ ] WASM server (http_listen/accept/respond): Phase 2。インタプリタのみ動作
- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応
- [ ] `moon info` mbti 自動再生成: `--deny-warn` が `unused_constructor` を error にするため循環依存
  - 回避: mbti を先に手動更新 → check

## Deferred

- none
