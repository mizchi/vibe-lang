# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Compiler Refactoring

- [x] `type_call` builtin チェックをカテゴリハンドラへ分割する
  - 対象: `src/checker/typecheck_call_builtin*.mbt`
- [x] `compile_call_by_name` をカテゴリ別 dispatch へ分割する
  - 対象: `src/codegen/wasm_codegen_call.mbt`, `src/codegen/wasm_codegen_call_dispatch_tail.mbt`
- [x] `MonoifyContext` を tag 推論/instantiation 管理まで拡張する
  - 対象: `src/frontend/monoify.mbt`
- [x] `TypeEnv` の namespace 解決ロジックを分離する
  - 対象: `src/checker/typecheck_env_namespace.mbt`, `src/checker/typecheck_call.mbt`
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
- [x] `normalize` オプション解析を厳格化する（未知オプションをファイル扱いしない）
  - 対象: `src/cmd/vibe/cli.mbt`, `src/cmd/vibe/cli_e2e_wbtest.mbt`
- [x] `normalize -o` を `--merge` 専用に制約し、誤用時は明示エラーにする
  - 対象: `src/cmd/vibe/cli.mbt`, `src/cmd/vibe/cli_e2e_wbtest.mbt`
- [x] `vibe-normalize --check` を非破壊化する（`--write` + `git checkout` を廃止）
  - 対象: `scripts/vibe_normalize_all.sh`

## vibe/ Library UX

### Keep Strengths

- [x] std 層境界のドキュメント参照先を実在パスに更新し、`check/normalize` 境界検証を維持する
  - 対象: `vibe/builtin/README.md`, `docs/adr/0005-std-layered-boundaries.md`, `src/cmd/vibe/normalize_engine.mbt`
- [x] effect 付きシグネチャの設計方針を明文化し、I/O API 追加時に逸脱を防ぐ
  - 対象: `vibe/builtin/README.md`, `vibe/fs/fs.vibe`, `vibe/http/http.vibe`, `vibe/socket/socket.vibe`
- [x] 関数スタイル/メソッドスタイル併用の回帰テストを追加して API 体験を維持する
  - [x] `vibe/builtin/array_test.vibe` で関数スタイル/メソッドスタイル parity を追加
  - [x] `vibe/collection/map_test.vibe` で関数スタイル/メソッドスタイル parity を追加
  - 対象: `vibe/builtin/*_test.vibe`, `vibe/collection/*_test.vibe`

### Improve Usability

- [x] 予約語回避由来の命名ゆらぎ（`map_opt`/`map_ok`/`array_map`）を整理し、推奨 API を一本化する
  - [x] `vibe/builtin/README.md` に canonical naming を明記し、`Option`/`Result`/`Array` の推奨名を固定
  - 対象: `vibe/builtin/option.vibe`, `vibe/builtin/result.vibe`, `vibe/builtin/array.vibe`, `vibe/builtin/README.md`
- [x] 同等 API の別名を段階的に縮小する方針（互換期間・deprecate ルール）を定義する
  - [x] `vibe/builtin/README.md` / `vibe/collection/README.md` に alias lifecycle ルールを追加
  - 対象: `vibe/builtin/option.vibe`, `vibe/builtin/result.vibe`, `vibe/collection/list.vibe`
- [x] `array_map` を `A -> B` 変換可能な汎用 map に拡張する
  - 対象: `vibe/builtin/array.vibe`, `vibe/builtin/array_test.vibe`
- [x] `for-in` の反復呼び出しを `iter_length` / `iter_get` 経由へ移行し、Array 直結 desugar を解消する
  - 対象: `src/parser/parser_ast_expr.mbt`, `src/checker/prelude.mbt`, `src/parser/parser_for_in_wbtest.mbt`
- [x] 反復プロトコルの上で `iter/zip/flatmap` を追加し、将来の trait 化（第2段階）へ繋ぐ
  - [x] `vibe/builtin/array.vibe` に `iter/zip/flatmap` を追加し、`vibe/builtin/array_test.vibe` で回帰を固定する
  - [x] `vibe/collection/list.vibe` へ同等 API を追加し、`vibe/collection/list_test.vibe` で回帰を固定する
  - 対象: `vibe/builtin/array.vibe`, `vibe/collection/list.vibe`, `vibe/builtin/README.md`
- [x] `Iterable` trait を導入し、`for-in` desugar と collection API を trait 契約に寄せる（第2段階）
  - [x] prelude に `Iterable` trait / `iter_require` を導入し、`for-in` desugar で trait gate を通す
  - [x] cross-module trait 制約（既知ギャップ）を解消し、`List` など利用側モジュールの impl を有効化する
  - [x] `run_script_tests` / `run_script_benches` の type env 同期と `for-in` 生成 span の衝突を解消し、runtime dispatch を安定化する
  - 対象: `src/checker/prelude.mbt`, `src/parser/parser_ast_expr.mbt`, `vibe/builtin/array.vibe`, `vibe/collection/list.vibe`
- [x] collection の型汎用性を拡張する（`Map` key 制約、`Set` の `StringSet` 専用性）
  - [x] `vibe/collection/map.vibe` に trait-bound key accessors (`has_by`/`get_by`/`get_or_by`) を追加し、非 String key の呼び出し面を統一する
  - [x] `vibe/collection/set.vibe` に trait-bound accessors (`contains_by`/`add_by`/`remove_by`/`from_array_by`) を追加し、`StringSet` API で非 String 値を扱えるようにする
  - 対象: `vibe/collection/map.vibe`, `vibe/collection/set.vibe`, `vibe/collection/README.md`
- [ ] `from_csv` / `from_yaml` の戻り値を JSON 文字列から構造化型へ寄せる設計を検討する
  - 対象: `vibe/shell/from_csv.vibe`, `vibe/shell/from_yaml.vibe`, `vibe/shell/pipeline.vibe`
- [ ] HTTP/Socket の高レベル API（request/response struct, header map, status helpers）を追加する
  - 対象: `vibe/http/http.vibe`, `vibe/socket/socket.vibe`, `vibe/http/*_test.vibe`, `vibe/socket/*_test.vibe`
- [ ] 文字列 `raise` 中心の失敗通知を `Result` ベース API に置き換える指針を作る
  - 対象: `vibe/encoding/json.vibe`, `vibe/encoding/jsonrpc.vibe`, `vibe/shell/from_csv.vibe`, `vibe/shell/from_yaml.vibe`
- [x] `path` facade と `path/ref` の型公開境界を整理し、利用者向け import ルールを一本化する
  - [x] `vibe/builtin/README.md` に facade / split import の推奨ルールを明文化
  - [x] `vibe/builtin/path_test.vibe`, `vibe/builtin/path_ref_test.vibe`, `vibe/builtin/path_runtime_test.vibe` で facade / split の利用経路を回帰維持
  - 対象: `vibe/builtin/path.vibe`, `vibe/builtin/path/ref.vibe`, `vibe/builtin/path/runtime.vibe`, `vibe/builtin/path*_test.vibe`
- [ ] `--unstable-threads` 依存 API の安定/実験境界をドキュメントとテストで明示する
  - 対象: `vibe/builtin/threads.vibe`, `vibe/builtin/threads/runtime.vibe`, `vibe/builtin/threads_test.vibe`, `vibe/builtin/README.md`

## Runtime

- [ ] `VibeDb` を import/query/graph/diagnostic 単位に分割する
  - 対象: `src/runtime/db.mbt`
- [ ] runtime package の責務を整理し、frontend 再公開 API を縮小する
  - 対象: `src/runtime/frontend_bridge.mbt`, `src/runtime/pkg.generated.mbti`
- [ ] `resume` の one-shot 実装で `perform` 前副作用が二重実行される問題を解消する
  - 対象: `src/runtime/eval.mbt`, `src/runtime/store.mbt`
- [ ] `resume` 引数型を継続先型と接続し、実行時型崩壊を型検査で防ぐ
  - 対象: `src/checker/typecheck_expr.mbt`, `src/checker/typecheck_env*.mbt`
- [ ] `perform` サイト識別キー（`start:end`）の衝突/リーク耐性を強化する
  - 対象: `src/runtime/eval.mbt`, `src/runtime/store.mbt`

## Testing

- [ ] `serialize` / `deserialize` の手書き対称実装に対して round-trip property test を追加する
  - 対象: `src/core/serialize.mbt`, `src/core/deserialize.mbt`

## Compiler / Language Incident Follow-up (2026-02)

- [x] `eval_report_json` の `value_type_name` で `@core.Value` の新規バリアントを取りこぼさない
  - 事象: `PromptText` 追加後に `build-wasm-vibe` が `partial_match` で失敗
  - 回帰テスト: `src/lib/lib_wbtest.mbt` (`eval_report_json` の `PromptText` 型名確認)
- [x] 旧 `import { ... } from ...` 記法の parse error を migration ヒント付きで固定する
  - 事象: `.vibe` の旧記法が混入すると parser で停止し、bundle-size case の mode が変わる
  - 回帰テスト: `scripts/test_codegen_unsupported.sh` (`use <module-ref> { ... }` を期待)
- [ ] bundle-size の `unsupported` baseline case と「現行構文のサイズ評価 case」を分離する
  - 目的: syntax migration と pure size regression を別軸で管理する
  - 対象: `bench/bundle_size/cases.txt`, `bench/golden/bundle_size_budget.tsv`, `bench/bundle_size/README.md`
- [ ] `examples/*.vibe` のサイズ予算運用ルール（テスト追加/関数追加の扱い）を明文化する
  - 目的: サンプル拡張で budget が偶発的に揺れる問題を防ぐ
  - 対象: `bench/bundle_size/README.md`, `docs/vibe.md`

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
