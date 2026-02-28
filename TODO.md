# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Playground

- [ ] CodeMirror 等のエディタ統合（シンタックスハイライト、補完）
- [ ] 複数スニペットのプリセット / URL 共有

## Self-host Compiler (`vibe/compiler/`)

- [ ] Self-hosting: vibe/compiler が vibe/compiler 自身を parse + eval する (要: throw/handle実装, array_builder mutation)
- [ ] `break` / `continue` を end-to-end で実装整合させる
  - parser: 受理位置の制約整理（while 文脈）
  - checker: while 外 `break` / `continue` を型エラー化
  - eval: ループ制御として正しく停止/継続させる
- [ ] `|>` を parser で desugar する
  - 合意方針: `x |> f(a, b)` => `f(x, a, b)` を parser で AST 変換
  - `|>` と他の二項演算混在時の曖昧性は parse error に統一
- [ ] `use` 構文を削除し、`import` に一本化する
  - lexer/parser/printer/fixture を `import` 正規形へ揃える
- [ ] 型注釈の契約層を実装に一致させる (`TyApp` / `TyFn` / `TyTuple` を `CtUnknown` に落とさない)
- [ ] postfix 構文と実行系のズレを解消する (`arr[i]`, `t.0`, member/index)
- [ ] 未接続キーワード/トークンを整理する (`do`, `loop`, `yield`, `return`, `raise`, `declare` など)
- [ ] builtins の型契約と evaluator 実装の差分を解消する（型のみ存在/実装のみ存在の不一致）
- [ ] incremental 型検査DBを checker パスへ統合する（現状 `type_db.vibe` は独立実験）
  - 現状制約: `db_typecheck` の公開シグネチャで `TypeEnv` を返すと `vibe test` 経由で `unknown type: TypeEnv` が発生
  - 対応方針: export/import 時の型解決バグを直すか、公開APIを `TypeEnv` 非依存に再設計する
- [ ] `type_db` の依存抽出を AST ベースに戻す（現状は lexer token 走査で暫定実装）

## Language Features

- [ ] Multi-language frontend adapters:
  tree-sitter-based extractor を baseline とし、optional semantic providers (compiler/LSP) で type-resolution gaps を補完。
  `vibe ide`/`vibe lsif` は shared backend API 上に維持。

## Bundle Size (In Progress)

目標: importer-level DCE で主要 std モジュールのサイズ最適化。

**最新 KPI (2026-02-15):**

| case | per_us | wasm_bytes | size_x_latency |
|------|--------|------------|----------------|
| pipeline_a | 0.528 | 1446 | 764 |
| pipeline_b | 0.539 | 1450 | 782 |
| pair_mix_ab | 0.579 | 1525 | 884 |
| cross_mix | 0.565 | 1571 | 887 |
| **avg** | **0.553** | **1498** | **829** |

**Importers (wasm with DCE):**

| file | bytes |
|------|-------|
| consumer_option_core | 1662 |
| consumer_option_extra | 1792 |
| consumer_double_core | 3251 |
| consumer_double_rounding | 7521 |

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
