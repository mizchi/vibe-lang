# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Workflow UX Audit (2026-02-25)

対象ワークフロー: 「POSIX 互換 shell に `|>` を拡張して動的評価し、`normalize` で整形し、commit/patch へ繋ぐ」

### Immediate fixes (done)

- [x] `eval --export` / `finalize --export` / `write_file` の相対パス解決を cwd 基準へ統一する
  - 対象: `src/cmd/vibe/eval_cmd.mbt`
  - 効果: `tmp_probe/...` が `/tmp_probe/...` へ誤解決される問題を解消
- [x] `shell-stdin --help` を受け付け、unknown arg ではなく usage を返す
  - 対象: `src/cmd/vibe/repl_line.mbt`, `src/cmd/vibe/cli_repl.mbt`

## Pipe-first Namespace & Symbol Migration (ADR-0020)

`|>` ファースト呼び出し、`.` の責務限定、`Type::symbol` 正規化を実装へ落とす。
仕様確定は `docs/adr/0020-pipe-first-namespace-and-symbol-resolution.md` を正とする。

### Spec lock (done)

- [x] ADR-0020 を accepted として追加
- [x] `spec/decisions.md` に lock 項目を追加
- [x] `docs/vibe.md` を `recv.method(...)` 非採用前提へ更新

### Implementation plan

- [x] parser: `recv.method(...)` を受理しない構文へ切り替え、`(obj.method)(...)` のみ許可する
  - 対象: `src/parser/*`, `src/parser/*_wbtest.mbt`
  - [x] Red: `recv.method(...)` が parse error になるテストを追加
  - [x] Green: 既存 postfix ルールから method-call sugar 分岐を削除
- [x] parser: `|>` と他の二項演算子混在の曖昧式を parse error 化する
  - 対象: `src/parser/parser_ast_expr.mbt`, `src/parser/*_wbtest.mbt`, fixtures
  - [x] Red: `1 + 1 |> double` / `a |> b + c` を失敗ケースとして固定
  - [x] Green: 括弧付き (`(1 + 1) |> double`) を許可
- [x] diagnostics: `|>` 曖昧式エラーで括弧追加の修正ヒントを提示する
  - 対象: `src/parser/*`, `src/core/diagnostic.mbt`, CLI 表示
- [x] checker: `.` は member/index アクセス専用に固定し、関数呼び出しへの fallback を撤去する
  - 対象: `src/checker/typecheck_call*.mbt`, `src/checker/typecheck_expr*.mbt`
  - [x] Red: call-style fallback (`prop(obj)`) 依存ケースを失敗として固定
  - [x] Green: data member access（`obj.prop`）+ tuple index を維持しつつ fallback を撤去
- [x] checker/runtime: 名前解決優先順位を `local > lexical > explicit import > prelude` に固定する
  - 対象: `src/runtime/db_query.mbt`, `src/runtime/eval.mbt`, `src/tests/vibe_*integration_test.mbt`
- [ ] normalize/edit: namespace symbol の正規形を `/pkg@version/module/Type::symbol` に統一し、内部参照を `<canonical>#<addr-hash>` 形式で保持する
  - 対象: `src/cmd/vibe/normalize_*`, `src/runtime/db*.mbt`, `src/core/*`
  - Red: 同名衝突時に安定した disambiguation を行う snapshot を追加
  - Green: 再展開時に決定的 import 生成（最短 import + 衝突時 alias）
- [ ] library migration: 既存ライブラリ/fixture の `recv.method(...)` 記法を `|>` または完全修飾関数呼び出しへ一括移行する
  - 対象: `vibe/**/*`, `examples/**/*`, `fixtures/**/*`, `docs/language-tour/*`
- [ ] railway-oriented error path: Result 合成チェーンの推奨パターンを lint/guide で固定し、例外境界 (`handle`/`throw`/`unwrap`) を可視化する
  - 対象: `docs/language-tour/effects.md`, `docs/vibe.md`, `src/cmd/vibe/normalize_format.mbt`（表示規約）

## Prelude Namespace Migration (2026-02-25)

`vibe/prelude` を常時解決可能 namespace として固定し、`vibe/builtin` 依存を段階的に縮小する。

- [x] 既定 registry に `prelude` を追加し、`std` を `vibe/prelude` へ解決する
  - 対象: `src/codebase/lib.mbt`, `src/codebase/codebase_test.mbt`
- [x] runtime の default namespace fallback に `prelude` を追加する
  - 対象: `src/runtime/db_import.mbt`, `src/runtime/db_wbtest.mbt`
- [x] `vibe new` seed を `vibe/prelude` 基準へ切り替える
  - 対象: `src/cmd/vibe/cli.mbt`, `src/cmd/vibe/cli_wbtest.mbt`
- [x] `vibe/prelude` パッケージを追加し、既存 `vibe/builtin` 相当 API を配置する
  - 対象: `vibe/prelude/**/*`
- [x] formatter/lsp/parser/loader/vibe_db の参照パスを `vibe/prelude` に寄せる
  - 対象: `src/cmd/vibe/normalize_format.mbt`, `src/lsp/*`, `src/parser/*`, `src/loader/loader_test.mbt`, `src/tests/vibe_db_integration_test.mbt`
- [x] `src/checker/builtin_modules*.mbt` の埋め込み namespace（`builtin/*`）を `prelude/*` に再設計する
  - 対象: `src/checker/builtin_modules.mbt`, `scripts/gen_builtin_embed.sh`, `src/checker/builtin_modules_wbtest.mbt`
- [x] `vibe/builtin` の重複コードを削除し、`vibe/prelude` へ一本化する
  - 対象: `vibe/builtin/**/*`, fixtures / docs / scripts / bench の `vibe/prelude` 参照

### Improvement plan

- [x] `finalize` 出力を常に normalize 済みに保つ（`safe`/`library` 両モード）
  - 対象: `src/cmd/vibe/cli.mbt`, `src/cmd/vibe/normalize_engine*.mbt`
  - 完了条件: `finalize` 直後に `normalize --check` が通る
  - メモ: `safe` モードでも pure な top-level expr statement は normalize で除去される
- [x] `eval --run` の UX 改善（`--test-for` 指定漏れ時の自動候補提示）
  - 対象: `src/cmd/vibe/cli_eval_helpers.mbt`
  - 完了条件: scope 内の test target 候補を表示し、次アクションを明確化
- [x] `eval --include` の相対パス基準を明確化し、`--db` 併用時の混乱を減らす
  - 対象: `src/cmd/vibe/cli_eval_helpers.mbt`, `src/cmd/vibe/eval_cmd.mbt`
  - 完了条件: cwd 基準 / db 親基準の仕様を固定し、CLI help + wbtest/e2e で回帰を防ぐ
- [x] scratch DB restore 警告の分離（致命エラーと非致命警告を区別）
  - 対象: `src/cmd/vibe/cli_eval_helpers.mbt`, `src/runtime/eval*.mbt`
  - 完了条件: 失敗理由ごとに actionable なメッセージへ統一
  - メモ: parse/unresolved/duplicate は non-fatal warning、その他は fatal 扱い
- [x] `shell-stdin` の `do { ... }` 入力時に parser mode 前提を明示する診断を追加
  - 対象: `src/cmd/vibe/cli_repl.mbt`, `src/parser/*`
  - 完了条件: 現状非対応構文での「次にどう書けばよいか」を提示
- [x] 上記ワークフローの E2E 回帰を追加（`eval -> finalize -> normalize -> apply`）
  - 対象: `src/cmd/vibe/cli_e2e_wbtest.mbt`
  - 完了条件: 相対パス・help・整形の回帰が CI で検出される

## Import/Export Model Refactor (2026-02-24)

### Spec lock (confirmed)

- [x] `use` を廃止し、`import <module-ref> { ... }` に一本化する
- [x] `declare` を廃止する
- [x] `export <module-ref> { ... }` を再 export 構文として導入する
- [x] `/index.vibe` は module ref 正規化で常に省略可能にする
- [x] 外部 import は `index.vibe` エンドポイント経由に統一する
- [x] `internal export` を導入する（`let` / `type` / `enum` / `trait`）
- [x] `extern let %name: Ty` を導入する（`%` 始まり識別子は予約）
- [x] `import` / `export` の item で `as` を許可し、衝突がない場合は normalize で簡約可能にする

### Implementation plan

- [x] parser/CST: `use` / `declare` 分岐を削除し、新構文（`import {}` / `export <ref> {}` / `internal export` / `extern let %`）を parse 可能にする
- [x] core AST: `internal export` と `extern` の表現を追加し、serialize/deserialize/hash/normalize/ast_walker を追従させる
- [x] checker/runtime: 新しい公開境界と import 規約（index endpoint 経由）で名前解決と可視性判定を更新する
- [x] normalize: 非 `index.vibe` の外部 import を index 経由形へ再配置する規約変換を追加し、`export <module-ref> { ... }` を先頭へ整列する
- [x] diagnostics: 旧構文 (`use` / `declare`) の migration error を明示する
- [x] tests: parser/runtime/CLI の旧構文ケースを新構文へ移行し、index 強制規約の回帰テストを追加する
- [x] vibe/ 配下ライブラリを新構文へ一括変換する

### Progress (2026-02-24)

- [x] parser: `use` / `declare` を parse error 化し、`import <ref> { ... }` / `export <ref> { ... }` / `extern let %name: Ty` を受理
- [x] parser-cst/formatter: `export <ref> { ... }` と `import ./foo` spacing を新構文に追従
- [x] core/checker/frontend/runtime/codegen: `Stmt::ExternLet` の match 網羅と最低限の型/IR 伝播を実装
- [x] fixtures: checker/runtime/cmd の主要 fixture を `use` -> `import` / `export use` -> `export` へ更新
- [x] `internal export` を AST レベルで独立可視性として表現し、checker/runtime の公開境界に反映する
- [x] `normalize_render` の旧 `declare export let` 互換ロジックを完全撤去し、`extern`/新 export 規約へ寄せる
- [x] checker builtin module source の旧 `declare export` を現行構文へ移行し、`builtin/int|float|double` の parse 回帰を追加する

## Compiler Refactoring

- [x] `type_call` builtin チェックをカテゴリハンドラへ分割する
  - 対象: `src/checker/typecheck_call_builtin*.mbt`
- [x] `compile_call_by_name` をカテゴリ別 dispatch へ分割する
  - 対象: `src/codegen/wasm_codegen_call.mbt`, `src/codegen/wasm_codegen_call_dispatch_tail.mbt`
- [x] `MonoifyContext` を tag 推論/instantiation 管理まで拡張する
  - 対象: `src/frontend/monoify.mbt`
- [x] `TypeEnv` の namespace 解決ロジックを分離する
  - 対象: `src/checker/typecheck_env_namespace.mbt`, `src/checker/typecheck_call.mbt`
- [x] `compile_expr` をノード別ハンドラに分割する
  - 対象: `src/codegen/wasm_codegen_expr.mbt`
- [x] Type member 解決ロジックを checker/runtime で共通化する
  - 対象: `src/core/ast.mbt`, `src/checker/typecheck_env_namespace.mbt`, `src/checker/typecheck_call.mbt`, `src/runtime/eval.mbt`
- [x] AST 参照収集 walker を共通化して重複実装を削減する
  - 対象: `src/core/ast_walker.mbt`, `src/frontend/dce.mbt`, `src/runtime/test_runner.mbt`, `src/cmd/vibe/normalize_optimize.mbt`
- [x] checker のグローバル mutable state (`global_next_type_var`, `cached_prelude_env`) をセッション化する
  - 対象: `src/checker/typecheck_env.mbt`, `src/checker/typecheck_stmts.mbt`

## CLI / Normalize

- [x] `normalize_engine` を pass 単位へ分解する (quickfix / optimize / render / sort)
  - 対象: `src/cmd/vibe/normalize_engine.mbt`
- [x] `normalize_engine` の専用テストファイルを追加し、pass 単位の snapshot 回帰を守る
  - 対象: `src/cmd/vibe/normalize_engine_pass_wbtest.mbt`
- [x] `cmd/vibe` の package 依存をサブコマンド単位に整理して未使用 import を解消する
  - 調査結果: 全36パッケージが実際に使用されており未使用 import なし
  - MoonBit は per-file import 非対応のため、サブコマンド分離には package 分割が必要
  - 現状の monolithic 構成はコア依存（runtime/parser/checker）を全コマンドが共有しており合理的
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
  - 対象: `vibe/prelude/README.md`, `docs/adr/0005-std-layered-boundaries.md`, `src/cmd/vibe/normalize_engine.mbt`
- [x] effect 付きシグネチャの設計方針を明文化し、I/O API 追加時に逸脱を防ぐ
  - 対象: `vibe/prelude/README.md`, `vibe/fs/fs.vibe`, `vibe/http/http.vibe`, `vibe/socket/socket.vibe`

### Improve Usability

- [x] 予約語回避由来の命名ゆらぎ（`map_opt`/`map_ok`/`array_map`）を整理し、推奨 API を一本化する
  - [x] `vibe/prelude/README.md` に canonical naming を明記し、`Option`/`Result`/`Array` の推奨名を固定
  - 対象: `vibe/prelude/option.vibe`, `vibe/prelude/result.vibe`, `vibe/prelude/array.vibe`, `vibe/prelude/README.md`
- [x] 同等 API の別名を段階的に縮小する方針（互換期間・deprecate ルール）を定義する
  - [x] `vibe/prelude/README.md` / `vibe/collection/README.md` に alias lifecycle ルールを追加
  - 対象: `vibe/prelude/option.vibe`, `vibe/prelude/result.vibe`, `vibe/collection/list.vibe`
- [x] `array_map` を `A -> B` 変換可能な汎用 map に拡張する
  - 対象: `vibe/prelude/array.vibe`, `vibe/prelude/array_test.vibe`
- [x] `for-in` の反復呼び出しを `iter_length` / `iter_get` 経由へ移行し、Array 直結 desugar を解消する
  - 対象: `src/parser/parser_ast_expr.mbt`, `src/checker/prelude.mbt`, `src/parser/parser_for_in_wbtest.mbt`
- [x] 反復プロトコルの上で `iter/zip/flatmap` を追加し、将来の trait 化（第2段階）へ繋ぐ
  - [x] `vibe/prelude/array.vibe` に `iter/zip/flatmap` を追加し、`vibe/prelude/array_test.vibe` で回帰を固定する
  - [x] `vibe/collection/list.vibe` へ同等 API を追加し、`vibe/collection/list_test.vibe` で回帰を固定する
  - 対象: `vibe/prelude/array.vibe`, `vibe/collection/list.vibe`, `vibe/prelude/README.md`
- [x] `Iterable` trait を導入し、`for-in` desugar と collection API を trait 契約に寄せる（第2段階）
  - [x] prelude に `Iterable` trait / `iter_require` を導入し、`for-in` desugar で trait gate を通す
  - [x] cross-module trait 制約（既知ギャップ）を解消し、`List` など利用側モジュールの impl を有効化する
  - [x] `run_script_tests` / `run_script_benches` の type env 同期と `for-in` 生成 span の衝突を解消し、runtime dispatch を安定化する
  - 対象: `src/checker/prelude.mbt`, `src/parser/parser_ast_expr.mbt`, `vibe/prelude/array.vibe`, `vibe/collection/list.vibe`
- [x] collection の型汎用性を拡張する（`Map` key 制約、`Set` の `StringSet` 専用性）
  - [x] `vibe/collection/map.vibe` に trait-bound key accessors (`has_by`/`get_by`/`get_or_by`) を追加し、非 String key の呼び出し面を統一する
  - [x] `vibe/collection/set.vibe` に trait-bound accessors (`contains_by`/`add_by`/`remove_by`/`from_array_by`) を追加し、`StringSet` API で非 String 値を扱えるようにする
  - 対象: `vibe/collection/map.vibe`, `vibe/collection/set.vibe`, `vibe/collection/README.md`
- [x] `from_csv` / `from_yaml` の戻り値を JSON 文字列から構造化型へ寄せる設計を検討する
  - 対象: `vibe/shell/from_csv.vibe`, `vibe/shell/from_yaml.vibe`, `vibe/shell/pipeline.vibe`
- [x] HTTP/Socket の高レベル API（request/response struct, header map, status helpers）を追加する
  - `vibe/http/high_level.vibe` に request/response struct + header map + status helper を追加
  - `vibe/socket/socket.vibe` に endpoint/connection wrapper を追加
  - テスト: `vibe/http/high_level_test.vibe`, `vibe/socket/socket_test.vibe`
- [x] 文字列 `raise` 中心の失敗通知を `Result` ベース API に置き換える指針を作る
  - ADR-0018 で移行方針を定義（`Result[T, String]` 基本、段階的移行、互換 alias）
  - 対象: `vibe/json/json.vibe`, `vibe/json/jsonrpc.vibe`, `vibe/shell/from_csv.vibe`, `vibe/shell/from_yaml.vibe`
- [x] `path` facade と `path/ref` の型公開境界を整理し、利用者向け import ルールを一本化する
  - [x] `vibe/prelude/README.md` に facade / split import の推奨ルールを明文化
  - [x] `vibe/path/index_test.vibe`, `vibe/path/ref_test.vibe`, `vibe/path/runtime_test.vibe` で facade / split の利用経路を回帰維持
  - 対象: `vibe/path/index.vibe`, `vibe/path/ref.vibe`, `vibe/path/runtime.vibe`, `vibe/path/*_test.vibe`
- [x] `--unstable-threads` 依存 API の安定/実験境界をドキュメントとテストで明示する
  - README に Stable/Unstable API 一覧表を追加（flag 要否、型チェック vs 実行の区別を明記）
  - テストは既存で十分（spec 5件 + runtime thunk 2件 + facade 7件 = 14テスト）
  - 対象: `vibe/prelude/threads.vibe`, `vibe/prelude/threads/runtime.vibe`, `vibe/prelude/threads_test.vibe`, `vibe/prelude/README.md`

## vibe/ API Ambiguity Audit (2026-02-25)

### High (P1): 公開エンドポイントの一貫性

- [x] `index.vibe` が `version` のみのモジュールで、公開 API を index に集約する
  - 対象: `vibe/x/rlm/index.vibe`, `vibe/x/index.vibe`, `vibe/x/args/index.vibe`, `vibe/path/index.vibe`, `vibe/prelude/threads/index.vibe`
  - 方針: 実体 API を `export ./foo.vibe { ... }` で明示し、利用側 import を index 経由へ寄せる

### Medium (P2): API 層と契約の明確化

- [x] `vibe/socket` の high-level (`TcpConnection`) と low-level (`tcp_*`) を分離し、推奨経路を固定する
  - 対象: `vibe/socket/index.vibe`, `vibe/socket/socket.vibe`
  - 方針: low-level は別エンドポイントへ分離するか、公開名を意図がわかる形に整理する

- [ ] `vibe/compiler` の AST 定義を単一ソース化し、`ast.vibe` と `parser.vibe` の型二重管理を解消する
  - 対象: `vibe/compiler/ast.vibe`, `vibe/compiler/parser.vibe`, `vibe/compiler/index.vibe`
  - 方針: `Pat`/`Expr`/`Stmt` の定義元を 1 箇所に統一し、差分 (`ELabeledArg` など) を吸収する

### Low (P3): 公開面のノイズ削減

- [x] `vibe/shell/from_yaml.vibe` の `_yaml_*` ヘルパー公開を縮小し、公開 API を `from_yaml` 中心に整理する
  - 対象: `vibe/shell/from_yaml.vibe`, `vibe/shell/index.vibe`

- [x] `vibe/collection/r#map.vibe` の利用者向け import 体験を改善する
  - 対象: `vibe/collection/index.vibe`, `vibe/collection/map.vibe`
  - 方針: `map` facade（別名モジュール）を用意し、`r#` 表記を公開面から隠す

- [x] endpoint 横断の同名シンボル衝突（`read`/`parse`/`run` など）に対する命名規約を定義する
  - 対象: `vibe/io`, `vibe/socket`, `vibe/http`, `vibe/process`, `vibe/compiler`, `vibe/json`, `vibe/base64`, `vibe/sha1`, `vibe/shell`, `vibe/fs`, `vibe/collection`, `vibe/prelude`
  - 方針: `as` 依存を前提にせず、衝突しやすい名前には module prefix 付きの canonical 名を用意する

## Runtime

### Execution strategy: Interpreter vs WASM

| | インタプリタ (eval) | WASM コンパイル |
|---|---|---|
| 用途 | REPL、テスト、簡易スクリプト | ベンチマーク、本番実行、重い計算 |
| 速度 | 遅い（AST walk、~100K iter/数秒） | ネイティブ近い速度 |
| 安全弁 | `loop_fuel` で反復上限（デフォルト 100K、`VIBE_LOOP_FUEL` で調整可） | OS レベルの制限 |
| コマンド | `vibe test`, `vibe shell` | `vibe bench`（デフォルト WASM）, `vibe compile` |

- `vibe bench` は WASM がデフォルト（`BenchBackend::Wasm`）、unsupported 時のみインタプリタ fallback
- インタプリタの `loop_fuel` は無限ループ防止の安全弁（CPU 300% 暴走を防ぐ）

- [x] `VibeDb` を import/query/graph/diagnostic 単位に分割する
  - 対象: `src/runtime/db.mbt`
- [x] runtime package の責務を整理し、frontend 再公開 API を縮小する
  - 対象: `src/runtime/frontend_bridge.mbt`, `src/runtime/pkg.generated.mbti`
- [x] `resume` の one-shot 実装で `perform` 前副作用が二重実行される問題を解消する
  - `has_prior_effect` ガードで prior effects がある場合は resume を拒否（runtime error）
  - 根本解決（continuation capture）は将来課題として残置
  - 対象: `src/runtime/eval.mbt`, `src/runtime/store.mbt`
- [x] `resume` 引数型を継続先型と接続し、実行時型崩壊を型検査で防ぐ
  - 対象: `src/checker/typecheck_expr.mbt`, `src/checker/typecheck_env*.mbt`
- [x] `perform` サイト識別キー（`start:end`）の衝突/リーク耐性を強化する
  - 調査済み:
    - 呼び出しカウンター方式 → resume が body を再評価するため deterministic key が必須。不可
    - `fork_for_test` で overrides クリア → fork は eval_block/eval_expr_with_bindings/import 解決にも使われ、スコープチェーン経由の override 伝播が壊れる。不可
    - `perform_site_key` にドキュメントコメント追加済み（known limitation: 異ファイル同一 span の衝突可能性）
  - 対応: handle body hash を site key namespace に組み込み、テストランナー fork 直後に overrides cleanup を実施
  - 対象: `src/runtime/eval.mbt`, `src/runtime/store.mbt`, `src/runtime/test_runner.mbt`

## Testing

- [x] `serialize` / `deserialize` の手書き対称実装に対して round-trip property test を追加する
  - 対象: `src/core/serialize.mbt`, `src/core/deserialize.mbt`

## Compiler / Language Incident Follow-up (2026-02)

- [x] `eval_report_json` の `value_type_name` で `@core.Value` の新規バリアントを取りこぼさない
  - 事象: `PromptText` 追加後に `build-wasm-vibe` が `partial_match` で失敗
  - 回帰テスト: `src/lib/lib_wbtest.mbt` (`eval_report_json` の `PromptText` 型名確認)
- [x] 旧 `import { ... } from ...` 記法の parse error を migration ヒント付きで固定する
  - 事象: `.vibe` の旧記法が混入すると parser で停止し、bundle-size case の mode が変わる
  - 回帰テスト: `scripts/test_codegen_unsupported.sh` (`import <module-ref> { ... }` を期待)
- [x] bundle-size の `unsupported` baseline case と「現行構文のサイズ評価 case」を分離する
  - `consumer_double_*.vibe` を `use` → `import` 構文に移行し、unsupported を解消
  - README に syntax migration vs size regression の分離ポリシーを明文化
  - 対象: `bench/bundle_size/cases.txt`, `bench/golden/bundle_size_budget.tsv`, `bench/bundle_size/README.md`
- [x] `examples/*.vibe` のサイズ予算運用ルール（テスト追加/関数追加の扱い）を明文化する
  - README に Examples Budget Rules セクション追加（変更種別ごとの対応表、3原則）
  - 対象: `bench/bundle_size/README.md`, `docs/vibe.md`

## Prelude API Consistency (2026-02)

prelude（REPL/スクリプトのデフォルト環境）と `vibe/prelude/` ライブラリ間の API 不整合を解消する。
`vibe/prelude/array.vibe` は既に正しい設計（ジェネリック、collection-first、Option 返し）だが、
prelude はレガシー設計（Num 型、fn-first、-1 sentinel）のまま。

### High: 構造的不整合

- [x] **H1: prelude HOF の引数順を collection-first に統一する**
  - `array_map(arr, fn)`, `array_filter(arr, fn)`, `array_fold(arr, init, fn)` (collection-first)
  - 対象: `src/checker/prelude.mbt`, `examples/*.vibe`, `docs/language-tour/*.md`, `eval-tasks.json`

- [x] **H2: `array_find` の -1 sentinel を廃止する**
  - `Option[Num]` を返す設計に変更（`Some(v)` / `None`）
  - 対象: `src/checker/prelude.mbt`, `examples/syntax.vibe`, docs, eval-tasks

- [x] **H3: `where` と `array_filter` の引数順不整合を解消する**
  - H1 で `array_filter(arr, pred)` に統一済み。`where` も同じ collection-first 順

### Medium: API ギャップ

- [x] **M1: `map_get_or` を prelude に追加する**
  - prelude 関数として `map_get_or(m, key, default)` を追加
  - 対象: `src/checker/prelude.mbt`

- [x] **M2: `assert_eq` を prelude に追加する**
  - `assert_eq(a, b)` を prelude 関数として追加（`__assert(eq(a, b))` のラッパー）
  - 対象: `src/checker/prelude.mbt`

- [x] **M3: `array_contains` を追加する**
  - prelude 関数として追加（直接ループ実装、クロージャキャプチャ問題を回避）
  - 対象: `src/checker/prelude.mbt`

- [x] **M4: `array_sort` を追加する**
  - prelude 関数として merge sort を実装（`array_slice` + `array_builder` ベース）
  - 対象: `src/checker/prelude.mbt`

- [x] **M5: Map HOF を追加する（`map_map`, `map_filter`）**
  - prelude 関数として `map_map(m, f)`, `map_filter(m, pred)` を追加
  - 対象: `src/checker/prelude.mbt`

### Low: 命名・細部

- [x] **L1: `array_join` alias を追加する**
  - `array_join(xs, sep)` = `string_join(xs, sep)` として prelude に追加
  - 対象: `src/checker/prelude.mbt`

- [x] **L2: prelude HOF を generics に移行する**
  - `Num` → `[T]` に変更: array_map, array_fold, array_filter, array_foreach,
    array_concat, array_any, array_all, array_find, array_reverse, where
  - `Num` → `[V]` に変更: map_get_or, map_map, map_filter
  - `Num` のまま（`eq`/`lt` 依存）: array_sort, array_contains, assert_eq
  - 対象: `src/checker/prelude.mbt`

## Playground

- [x] ブラウザ上で vibe コードを eval する最小プレイグラウンドを作成する
  - Vite + TypeScript、`createVibeService()` 経由で WASM eval
  - 対象: `playground/`
- [x] GitHub Pages へ自動デプロイする CI を構築する
  - `main` push + `workflow_dispatch` で `https://mizchi.github.io/vibe-lang/` にデプロイ
  - 対象: `.github/workflows/playground.yml`
- [ ] CodeMirror 等のエディタ統合（シンタックスハイライト、補完）
- [ ] 複数スニペットのプリセット / URL 共有
- [ ] `service.check()` によるリアルタイム diagnostics 表示

## Self-host Compiler (`vibe/compiler/`)

Total: 126 tests (lexer: 20, parser: 27, printer: 21, stmt: 46, fixture: 12)

### Phase 1: Lexer + AST + Expression Parser (completed)

- [x] `token.vibe` — Token enum (~50 variants) + `token_to_string`
- [x] `ast.vibe` — Pat, Expr enum definitions
- [x] `lexer.vibe` + `lexer_test.vibe` — String → Array[Token] (20 tests)
- [x] `parser.vibe` + `parser_test.vibe` — Array[Token] → Expr (27 tests)
- [x] `printer.vibe` + `printer_test.vibe` — Expr → String (21 tests, roundtrip)
- [x] `index.vibe` — Public API re-export

### Phase 2: Statement Parser + Type Annotations (completed)

- [x] `TypeExpr` enum + `parse_type` — type annotation parsing
- [x] `Stmt` enum + statement parsers — 13 variants (SLet, SLetMut, SEnum, SStruct, STypeAlias, STrait, SImpl, SImport, STest, SBench, SExpr, SExport, SModule)
- [x] `parse_stmt` + `parse_program` — top-level statement dispatch
- [x] `print_type_expr` + `print_stmt` + `print_program` — printer extensions
- [x] `stmt_test.vibe` — 46 tests

### Phase 3: Fixture Compatibility (completed)

- [x] Comma separator in enum/struct fields (normalized to `;` on output)
- [x] Effect annotation `() -> Int with {Error} { body }` in lambda expressions
- [x] `export module name { stmts }` block parsing (SModule with Array[Stmt])
- [x] Labeled params `x~: Int` and labeled args `x~=1`, `x?=2`, `x=1` (ELabeledArg)
- [x] EFn extended with `Option[String]` return type annotation
- [x] `fixture_test.vibe` — 6 fixtures × parse + roundtrip = 12 tests
- [ ] `suberror` declaration parsing
- [ ] `extern let %name: Type` parsing

### Phase 4: Parse own source (not started)

Cannot parse vibe/compiler/*.vibe itself yet. Missing AST nodes:

- [ ] `while` loop expression
- [ ] `do { ... }` block expression
- [ ] `handle { ... } { Error(msg) => ... }` effect handler
- [ ] `throw(msg)` expression
- [ ] `for ... in` loop
- [ ] `break` / `continue` / `return`

### Self-host quality baseline (方針メモ)

- Self-host compiler が生成するコードの品質がベースラインを満たすようにする
  - normalize / format 後のコードが host compiler と同等の出力になること
  - 既存テスト suite (631+) が回帰なしで通ること
- 既存ライブラリを WIT (WASI Component Model) で compose して再利用する選択肢あり
  - lexer/parser を component として切り出し、host runtime と組み合わせ可能にする

### Phase 5: Type Checker (not started)

- [ ] Type inference (Hindley-Milner with unification)
- [ ] Effect checking (`with { Error }` propagation)
- [ ] Import resolution (`import ./foo.vibe { ... }` file loading)
- [ ] Trait constraint resolution

### Phase 6: Interpreter / Codegen (not started)

- [ ] Builtin functions (~30: string_concat, array_get, etc.)
- [ ] AST evaluator (eval)
- [ ] Self-hosting: vibe/compiler parses + evaluates vibe/compiler itself

### Language pain points discovered during self-hosting

#### Reality check (2026-02)

- [x] Forward reference / mutual recursion は本体 checker で実装済み
  - `typecheck_stmts` の pre-scan provisional scheme で解決（`src/checker/typecheck_stmts.mbt`）
- [x] 文字列補間は実装済み（`"\(expr)"`）
  - parser desugar あり（`src/parser/parser_ast_expr.mbt`）
- [x] 複数行文字列は実装済み（`#| ...`）
  - lexer 実装あり（`src/parser/lexer.mbt`）
- [x] 反復 helper（`array_map/filter/fold`）は prelude で提供済み
  - language tour / quick-start 側も反映済み

#### Remaining language UX debts

- [x] Cascading diagnostics を根治する（import 先エラーが `unknown function/type` に潰れる問題）
  - 対象: `src/runtime/db_query.mbt`, `src/runtime/db.mbt`, `src/core/diagnostic.mbt`, `src/cmd/vibe/cli.mbt`
  - [x] Red: 依存モジュール failure 時に importer 側へ根本原因が見えない回帰テストを追加
    - `src/runtime/db_wbtest.mbt`
  - [x] Green: import 解決で `exported_names` に存在するが `get_scheme/get_type_alias/...` が欠落した場合、
    明示的な import diagnostic（「dependency export unavailable due to upstream errors」）を出す
  - [x] Green + Refactor: CLI `check` で依存先の診断を entry 前に表示（root cause 優先順）
    - `Diagnostic` struct 変更なし（52箇所の churn 回避）。CLI 側で `db.imports()` を辿り依存先診断を先行表示

- [x] `StateLocal`/`do {}` ノイズを削減する（局所変異なのに top-level 不純扱いされる問題）
  - 対象: `src/checker/purity.mbt`, `src/checker/typecheck_errors.mbt`, `docs/language-tour/*.md`
  - [x] Red: escape しない builder 使用を含む binding が `TopLevelImpure(StateLocal)` で落ちるケースを固定
    - `src/checker/purity_wbtest.mbt`
  - [x] Green: `check_toplevel_purity` で binding 間の purity tier を `PurityScope` 経由で伝播。`purity_for_let_in_scope` の effects 宣言チェック欠落を修正
  - [x] Green: 診断 hint を実装仕様に合わせて更新（許容される局所変異パターンを案内）
  - [x] Refactor: docs の `do` 必須説明を条件付き（必要なケースのみ）へ再整理

- [x] self-host compiler 向けの反復ボイラープレート削減
  - 既存の `for-in` 構文で十分対応可能（新 syntax 不要）
  - [x] Refactor: `vibe/compiler/printer.vibe` の `while + array_builder` パターン（~14箇所）を `for-in` へ移行
  - parser.vibe は全て recursive descent parsing パターンのため for-in 不適格

## Documentation

- [x] `docs/language-tour/syntax-reference.md` — Complete syntax reference
- [x] `docs/language-tour/effects.md` — Detailed effects guide (perform/resume, suberror, algebraic effects)
- [x] `docs/language-tour/modules.md` — Module system guide (import, export, module blocks, extern)

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
