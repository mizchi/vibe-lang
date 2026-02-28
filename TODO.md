# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Playground

- [ ] CodeMirror 等のエディタ統合（シンタックスハイライト、補完）
- [ ] 複数スニペットのプリセット / URL 共有

## Self-host Compiler (`vibe/compiler/`)

- [ ] Self-hosting: vibe/compiler が vibe/compiler 自身を parse + eval する（最終ゲート）
- [x] Gate 0: selfhost smoke suite を安定通過
  - `eval_selfhost_test.vibe`
  - `eval_selfhost2_test.vibe`
  - `eval_selfhost3_test.vibe`
- [ ] Gate 1: 実行制御の整合（ループ制御を実運用可能にする）
  - `break` / `continue` の parser/checker/eval を end-to-end で一致
  - `return` の仕様を確定し、未対応なら明示的に構文拒否を固定
  - DoD: ループ制御の fixture/e2e を追加して green
- [ ] Gate 2: 構文と実行系のギャップを解消
  - postfix 構文 (`arr[i]`, `t.0`, member/index) の parse/check/eval を一致
  - 未接続キーワード/トークン (`do`, `loop`, `yield`, `raise`, `declare`) の方針確定（実装 or reject）
  - DoD: `vibe/compiler` ソースで使う構文が parse/eval 双方で未接続なし
- [ ] Gate 3: 型契約を自己適用レベルに引き上げる
  - 型注釈の契約層を実装に一致させる (`TyApp` / `TyFn` / `TyTuple` を `CtUnknown` に落とさない)
  - builtins の型契約と evaluator 実装の差分を解消する（型のみ存在/実装のみ存在の不一致）
  - DoD: selfhost で使う主要 builtins の型/実装差分が 0
- [ ] Gate 4: 依存計算と incremental checker を本線化
  - incremental 型検査DBを checker パスへ統合する（現状 `type_db.vibe` は独立実験）
  - 現状制約: `db_typecheck` の公開シグネチャで `TypeEnv` を返すと `vibe test` 経由で `unknown type: TypeEnv` が発生
  - 対応方針: export/import 時の型解決バグを直すか、公開APIを `TypeEnv` 非依存に再設計する
  - `type_db` の依存抽出を AST ベースに戻す（現状は lexer token 走査で暫定実装）
  - `vibe/compiler` から `vibe/x` を直接 import できないルート制約を解消し、`ripple` 実装を一本化する
  - `vibe/module/path`（`dir_of` / `resolve_path`）へ compiler 側 path 解決処理を寄せる（ルート制約解消後）
  - DoD: 同一入力で cold/warm の型検査結果が一致し、差分更新のみ再計算される
- [ ] Gate 5: full self-host
  - `vibe/compiler` 一式を `parse + eval` して主要ワークフローを実行可能にする
  - DoD: selfhost 用トップレベル e2e（実ソース入力）を CI で常時 green

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
| consumer_double_core | 2144 |
| consumer_double_rounding | 5598 |

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
