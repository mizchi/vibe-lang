# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Compiler Refactoring

- [ ] `type_call` を責務別に分割する
  - 対象: `src/checker/typecheck_expr.mbt`
- [ ] `compile_expr` をノード別ハンドラに分割する
  - 対象: `src/codegen/wasm_codegen_expr.mbt`
- [ ] Type member 解決ロジックを checker/runtime で共通化する
  - 対象: `src/checker/typecheck_expr.mbt`, `src/runtime/eval.mbt`
- [ ] AST 参照収集 walker を共通化して重複実装を削減する
  - 対象: `src/frontend/dce.mbt`, `src/runtime/test_runner.mbt`, `src/cmd/vibe/normalize_engine.mbt`
- [ ] checker のグローバル mutable state (`global_next_type_var`, `cached_prelude_env`) をセッション化する
  - 対象: `src/checker/typecheck_env.mbt`, `src/checker/typecheck_stmts.mbt`

## CLI / Normalize

- [ ] `normalize_engine` を pass 単位へ分解する (quickfix / optimize / render / sort)
  - 対象: `src/cmd/vibe/normalize_engine.mbt`
- [ ] `normalize_engine` の専用テストファイルを追加し、pass 単位の snapshot 回帰を守る
  - 対象: `src/cmd/vibe/*test*.mbt`
- [ ] `cmd/vibe` の package 依存をサブコマンド単位に整理して未使用 import を解消する
  - 対象: `src/cmd/vibe/moon.pkg`

## Runtime

- [ ] `VibeDb` を import/query/graph/diagnostic 単位に分割する
  - 対象: `src/runtime/db.mbt`
- [ ] runtime package の責務を整理し、frontend 再公開 API を縮小する
  - 対象: `src/runtime/frontend_bridge.mbt`, `src/runtime/pkg.generated.mbti`

## Testing

- [ ] `serialize` / `deserialize` の手書き対称実装に対して round-trip property test を追加する
  - 対象: `src/core/serialize.mbt`, `src/core/deserialize.mbt`

## Language Features

- [ ] Multi-language frontend adapters:
  tree-sitter-based extractor を baseline とし、optional semantic providers (compiler/LSP) で type-resolution gaps を補完。
  `vibe ide`/`vibe lsif` は shared backend API 上に維持。
- [ ] Object pipeline operators on typed rows:
  record-like objects に対する first-class `where/select` contracts と `|>` chain の parser/desugar/typecheck 対応。
- [ ] Syntax profile controls:
  `--syntax posix-strict` vs `posix-ext` split と CI 向け strict compatibility diagnostics。
- [ ] `sh_lines` preview backend を host-backed execution strategy に置換:
  native target は real process output capture、non-native targets は deterministic fallback + capability diagnostics。

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
