# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## Playground

- [x] 複数スニペットのプリセット / URL 共有

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

## Self-host Next Checklist (Execution)

- [x] 作業ツリー整理ポリシーを固定する（`tmp_probe` / `.tmp_*` の扱い、コミット対象の境界を明文化）
  - `.gitignore` に `tmp_probe/`, `vibe/compiler/.tmp_*`, `vibe/compiler/.vibe_test_wasm_*` を追加して、生成物の混入を防止
- [x] selfhost bootstrap gate の再現性を固定する（stale `vibe.exe` を使わない）
  - `scripts/test_selfhost_bootstrap_gate.sh` で `src/**/*.mbt` / `moon.pkg` / `moon.mod.json` の更新を見て `vibe.exe` を再ビルド
- [x] `wasm-codegen-integrity` CI で selfhost gate の所要時間と失敗ログの可観測性を整える
  - `scripts/test_selfhost_bootstrap_gate.sh` にステージ別経過秒ログを追加し、`GITHUB_STEP_SUMMARY` へ実行時間を出力
- [x] stage0 wasm compiler (`vibe_compile_wasi`) で selfhost compiler (`vibe/compiler/index.vibe`) を stage1 wasm へセルフビルドし、実行できることを gate 化する
  - `scripts/test_selfhost_wasi_selfbuild.sh`（2回ビルド hash 一致 + wasm validate + wasmtime `--invoke run` 成功）
- [x] I/O 境界を `wasi:http` 接続で動作させる（HTTP builtins 固有実装は一旦後回し）
  - `scripts/test_selfhost_wasi_http_boundary.sh` で stage0 wasm compiler 経由の `--component` / `--wit-component` を検証
  - component WIT の `wasi:http/types@0.3.0-draft` / `wasi:http/client@0.3.0-draft` import を gate 化（client builtin 利用時）
  - HTTP サンプルの component validate を fatal gate 化（`wasm-tools validate --features all` + 構造チェック）
- [x] `wite optimize` / `wac compose+optimize` の wasm sidecar CLI を用意し、selfhost 側から外部呼び出し可能にする
  - `src/cmd/vibe_wite_optimize_wasi` を追加（`--wac` と `-O*` をサポート）
  - `wasm-gc` 入力は gc 互換フォールバック（type-form 未対応パスを無効化）で fail-open する
  - selfhost 側は `process.run` / `sh` で sidecar を呼び出す
- [x] WASM server Phase 2（`http_listen/accept/respond`）の実装計画を確定する
  - [x] Phase 2-1: API 契約を固定（`http_listen/accept/respond` の戻り値・エラー契約を明文化）
    - `docs/http_server_contract.md` を追加
    - checker/runtime wbtest で型契約 + エラー契約を固定
  - [x] Phase 2-2: runtime/capability ルーティング（`Net` effect から WASI HTTP 境界への接続）を実装
    - 進捗: interpreter runtime で `NetListen` capability を `http_listen/accept/respond` に適用（`PermissionDenied: net_listen/net_accept/net_respond`）
    - 進捗: interpreter runtime で `NetConnect` capability を `http_request` / `socket_tcp_connect` に適用（URL host/port 抽出 + `PermissionDenied: net_connect:<host>:<port>`）
    - 進捗: interpreter runtime で HTTP handle 系 builtin に capability check を適用（client: `net_response_*` / `net_close`, server: `net_request_*`）
    - 進捗: wasm host-import e2e で `PermissionDenied: net_connect:<host>:<port>` / `net_response_status` / `net_listen:<port>` / `net_accept` を再現し、allowlist（`connect_any` + `listen_any`）時のみ通過することを gate 化（`scripts/test_http_wasm_host_imports.sh`）
    - 進捗: wasm host-import e2e の allow ケースに `http_request_method` / `http_request_url` / `http_request_header` / `http_request_body` を追加し、request handle API の host-import ルーティングを固定
    - 進捗: `vibe run/test` の compiled backend で HTTP builtin 検出時は `--http-host-imports` 付き wasm を生成し、`scripts/wasm_http_host_runner.js` 経由で `vibe:http` host runtime を自動接続（interpreter fallback 依存を解消）
    - 進捗: auto/forced compiled の双方で上記経路が動作することを CI gate 化（`scripts/test_compiled_backend_http_policy.sh`）
  - [x] Phase 2-3: codegen 側ホスト呼び出しの導線を追加（interpreter と wasm の挙動差分を吸収）
    - wasm codegen に `http_host_imports` オプションを追加し、HTTP builtin を `vibe:http/*` import へルーティング可能にした（デフォルトは既存 fallback throw を維持）
    - `vibe compile` / `vibe_compile_wasi` に `--http-host-imports` を追加し、runtime_compile まで伝播（`--wasm` / `--component` 系）
    - import を持つ core wasm を component 側で instantiate できるように、core import を component import + canon lower で受ける導線を追加
  - [x] Phase 2-4: component WIT/export 仕様を固定し、`wasm-tools validate --features all` を gate 化
    - `scripts/test_component_import_contract.sh` と `scripts/test_selfhost_wasi_http_boundary.sh` で validate + import/instantiate contract を CI で常時検証
  - [x] Phase 2-5: e2e（request -> handler -> respond）を fixture 化し CI 常時 green にする
    - `scripts/test_http_wasm_host_imports.sh` で request/response/listen/accept/respond の往復と呼び出し順を検証し、`wasm-codegen-integrity` で常時実行
- [x] `moon info` mbti 自動再生成の循環依存問題を解消する（回帰ゲート化）
  - `scripts/test_moon_info_regen.sh` を追加（`moon info` 2回実行の idempotency + `moon check --deny-warn`）
  - `wasm-codegen-integrity` CI に再生成ゲートを追加

**現状 (18 ファイル中 18 OK):**

| 状態 | ファイル |
|------|---------|
| OK | eval_e2e_helpers, index, checker_resolve, ast, eval_loader, checker_stmt, values, token, eval_stmt, type_db, checker, printer, builtins, eval_builtins, lexer, types |
| OK | parser.vibe, eval.vibe — native roundtrip テスト（host の format_script + parse_ast）で検証済み |

**修正済みエラーパターン:**

- [x] P1: printer の文字列エスケープ — `escape_string` ヘルパー追加（`\"` `\\` `\n` `\t` `\r` `\0`）
- [x] P2: lexer のシングルクォート対応 — `lex_char` 関数追加（`'a'` → `TInt(97)`）
- [x] P3: printer の ELet/ESeq ブレース囲み — `ELet`, `ELetRec`, `ELetMut`, `EAssign`, `EAssignOp`, `ESeq` を `{ }` で出力
- [x] P4: parser のブロック内暗黙シーケンス — `parse_block_after_expr` の `_` ケースで mode 20 継続
- [x] P5: import パス内キーワードトークン — `TModule`, `TType`, `TMatch`, `TTest` を `collect_import_path` に追加
- [x] P6: if-without-else 対応 — parser: `EIf(cond, then, EUnit)` 返却、printer: else 省略

**残タスク:**

- [x] parser.vibe / eval.vibe の roundtrip 対応（native roundtrip テストで検証済み）

## Language Features

- [x] Multi-language frontend adapters:
  tree-sitter-based extractor を baseline とし、optional semantic providers (compiler/LSP) で type-resolution gaps を補完。
  `vibe ide`/`vibe lsif` は shared backend API 上に維持。
  - [x] 拡張子判定を拡張（`.mts`/`.cts`/`.mjs`/`.cjs`/`.pyi`）
  - [x] baseline extractor に optional semantic provider フックを追加（row merge API + `vibe ide/lsif` 接続）
  - [x] `vibe ide` / `vibe lsif` に `--semantic-rows <json>` を追加（外部 semantic row を merge）

## Bundle Size (In Progress)

目標: importer-level DCE で主要 std モジュールのサイズ最適化。

**Importers (wasm with DCE, 2026-03-05):**

| file | bytes |
|------|-------|
| consumer_option_core | 923 |
| consumer_option_extra | 1352 |
| consumer_double_core | 1764 |
| consumer_double_rounding | 4942 |

ベンチ: `scripts/bench_bundle_size.sh`, `bench/bundle_size/cases.txt`

- [x] Push/PR CI の product bundle-size を blocking gate 化（`scripts/bench_bundle_size.sh`）
- [x] 現行 baseline へ `bench/golden/bundle_size_budget.tsv` を更新し、gate を green 化
- [x] compiler bundle-size 予算 (`bench/golden/compiler_bundle_size_budget.tsv`) も現行 baseline に同期

## WASM Codegen Integrity (In Progress)

目標: selfhost 系ワークロードで生成される wasm が常に validate 可能で、PR/Push CI で回帰を検知できること。

- [x] type section の builtin signature 数を import 実体と一致させる（`need_fs`/`need_socket` を `builtin_type_count` に反映）
- [x] mut-captured local の kind 推論を boxed value 扱いに補正する（`infer_expr_kind`）
- [x] tagged value を保持する一時ローカルを i64 化する（`__to_string` / `__set_index`）
- [x] `handle` codegen の catch を `catch_all` 依存から error-tag catch へ修正し、catch payload の型を一致させる
- [x] 回帰 wbtest を追加して固定化（type index / handle catch encoding）
- [x] `selfhost_probe_types_run.vibe` を正式 fixture 化し、ad-hoc ファイル依存をなくす
- [x] Push/PR CI に wasm validate gate を追加（`vibe.exe compile --wasm` + `wasm-tools validate --features all`）
- [x] 上記 gate は定期実行なし（schedule なし）で運用する
- [x] `handle`/例外経路の interpreter vs wasm 実行結果一致テストを追加する
- [x] `vibe run` と `vibe_wasm (core/component)` の実行結果一致を gate 化する
  - `scripts/test_vibe_wasm_compare.sh`（`main_wbtest` 実行 + `vibe_wasm compare` の 3 モード status=0 を検証）
- [x] HTTP builtins の wasm fallback を catchable throw へ固定化し、`--debug-errors` でも validate + 実行可能な回帰テストを CI に追加する（`scripts/test_http_wasm_fallback.sh`）
- [x] `while`/`loop` の codegen で block result(i64) のスタック整合を修正（`break` 値経路と fallthrough 経路の validate 失敗を解消）
- [x] multi-value codegen で tuple 要素数と期待 arity の不一致を吸収し、`values remaining on stack` を解消
- [x] `vibe test` / `vibe run` の auto backend で `vibe/compiler/` 配下は compiled を優先（env 未指定時）
- [x] compiled backend の selfhost parity 回復
  - 2026-03-03: file-by-file 実測（`VIBE_TEST_BACKEND=compiled just run test vibe/compiler/*_test.vibe`）は **392/392 pass, 0 fail**
  - 主要修正:
    - `string_starts_with` / `string_ends_with` / `string_last_index_of` の codegen fallback 欠落を解消
    - `array_builder` / `string_builder` の固定容量不足（`256 -> 4096`）で発生していた token 破壊を解消
    - `types_equal` を構造比較へ変更し、`subst_apply(CtVar)` の循環解決を loop + cycle guard 化
    - wasm `__to_string` の `tag_obj` 分岐で `obj_float` / `obj_double` を実数文字列化し、`obj_string` 以外を `<value>` fallback に統一
    - `vibe/compiler` 側の数値文字列化を `double_to_string_compiler` から `__to_string(Double/Float)` に戻し、compiled backend と parity を固定
- [x] selfhost bootstrap gate を Push/PR CI に追加
  - `scripts/test_selfhost_bootstrap_gate.sh`
  - 構成:
    - `VIBE_TEST_BACKEND=compiled` で `vibe/compiler/*_test.vibe` を実行
    - `vibe_integration_test` index 44（selfhost probe smoke）を実行
    - `vibe/compiler/index.vibe` の `--wasm` 連続2回出力の hash 一致を検証（deterministic compile）
- [x] `vibe run/test` の実行ポリシーを compiled 本線へ寄せる（shell 系のみ interpreter 運用）
  - `run/test` の auto backend は compiled を先行し、既定では interpreter fallback しない
  - fallback が必要な場合のみ `VIBE_ALLOW_INTERPRETER_FALLBACK=1` で明示的に許可
- [x] selfhost WASI selfbuild gate を stage0 -> stage1 -> stage2 へ拡張
  - stage0 は `moon run --target wasm src/cmd/vibe_compile_wasi` で stage1 wasm を生成
  - stage1 は `moon run --target wasm` で生成された `vibe_compile_wasi.wasm` を `moonrun` で実行して stage2 wasm を生成
  - `scripts/test_selfhost_wasi_selfbuild.sh` で stage1/stage2 wasm の hash 一致を検証
  - strict 再帰チェックは `VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE=1` で有効化（デフォルト entry/out では stage1 生成物の `selfbuild_compile_stage2` を `scripts/wasm_vibe_host_runner.js` 経由で実行し、未達時は seed compiler fallback をログ化）
  - true recursive を必須化する場合は `VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE=1`（fallback 無効化・未達時 fail）
  - CI (`wasm-codegen-integrity`) では上記を `STRICT_RECURSIVE=1` + `REQUIRE_TRUE_RECURSIVE=1` で常時検証
  - stage1/stage2 の双方を `wasmtime --invoke run` で実行し、戻り値を検証
- [x] selfhost bootstrap gate に compile/run 段階計測と KPI 判定を追加
  - parse/type check, codegen(no-dce), validate, run(stage1/stage2) を段階ログ化
  - `VIBE_SELFHOST_BOOTSTRAP_BASELINE_SEC` と `VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT`（default 30）で目標時間を gate 化
  - Push/PR CI は baseline=180s, reduction=30%（target<=126s）で回帰を fail-fast
  - `compiled selfhost test suite` は `--jobs` 並列を既定化（`VIBE_SELFHOST_BOOTSTRAP_TEST_JOBS` で上書き可、default=`min(cpu,8)`, max 16）
  - `VIBE_TEST_BATCH_WEIGHT_CACHE` で過去実行時間を再利用し、バッチ分割を重み付きへ最適化（cold start は `scripts/selfhost_test_batch_weights.seed.json` を seed）
  - `VIBE_SELFHOST_BOOTSTRAP_STAGE_TIMEOUT_SEC` / `VIBE_SELFHOST_SELFBUILD_STAGE_TIMEOUT_SEC` で stage timeout を適用
  - optimize 段階は `VIBE_SELFHOST_PIPELINE_OPT_LEVEL` 指定時のみ実行（長時間化の回避）
- [x] selfhost workload coverage gate を追加（point/line/branch）
  - `vibe/compiler/selfhost_coverage_run.vibe` で lex/parse/print/eval/import の smoke workload を実行
  - `just coverage-selfhost-gate` で `point>=23`, `line>=100`, `branch>=20` を検証
  - `just coverage-selfhost-suite-gate` で `selfhost_coverage_run + index invoke + eval_e2e_test(run_tests) + fixture_test(run_tests)` 合算 (`point>=22`, `line>=97`, `branch>=18`) を検証
  - CI (`wasm-codegen-integrity`) に `Selfhost suite coverage gate` ステップを追加

## Selfhost Cutover Roadmap (MoonBit -> vibe selfhost, non-HTTP-P3)

スコープ: HTTP P3 本実装（`wasi:http@0.3` の client/server 実 lower, serve e2e）は除外。  
目標: `vibe` のコンパイラ本線を MoonBit 実行経路から selfhost 実行経路へ段階切替し、CI で回帰を検知できる状態にする。

- [x] Phase 0: 切替判定基準を固定する（測定軸 + 対象セット）
  - DoD: canary セット（最低 `examples/basics.vibe`, `vibe/compiler/index.vibe`）で以下を比較可能
    - compile 成否、exit code、stdout/stderr 形式
    - wasm bytes/hash（host vs selfhost）
    - 2 回連続 compile の deterministic hash
  - `scripts/test_selfhost_cutover_compare.sh` で canary ベースの host/selfhost 比較を実装
- [x] Phase 1: selfhost compiler CLI 契約を host と揃える
  - [x] `vibe_compile_wasi` の `--wasm` を MVP に統一（host と同じ `CompileMode::Wasm`）
  - [x] compile 失敗時は必ず非0 exit を返す（`abort("compile failed")` で trap 化）
  - [x] host CLI と同じオプション契約に揃える（`--debug-errors` 追加、`--wasm --http-host-imports` 許可）
- [x] Phase 2: 出力同値性（artifact parity）を gate 化する
  - [x] host (`vibe compile`) と selfhost (`moonrun vibe_compile_wasi.wasm`) で wasm 出力 hash 一致テストを追加
  - [x] mismatch 時に最小 diff（bytes/hash/size）を出す比較スクリプトを追加
  - [x] canary から compiler_size ケースへ比較対象を拡張（`VIBE_CUTOVER_INCLUDE_COMPILER_SIZE=1`）
  - [x] parity fail をデフォルト fatal 化（`VIBE_CUTOVER_REQUIRE_PARITY=1`）し、compiler_size canary もデフォルト有効化
  - [x] multi-mode parity（`--wasm`, `--wasm --no-dce`, `--wasm --debug-errors`）を常時比較
  - [x] expected-fail parity（parse/type/io エラー fixture）を mode ごとに比較し、失敗分類の不一致も fail-fast
  - [x] expected-fail で主要メッセージ断片（`UnexpectedToken` / `type mismatch (argument)`）の存在も host/selfhost 両方で検証
  - [x] expected-fail case 定義を `bench/selfhost_cutover/fail_cases.txt` へ外出し
  - [x] fail case を拡張（syntax: missing `from`, type: unknown name）して分類カバレッジを強化
  - [x] required fail classes（`parse,type,io`）を gate 化し、case 欠落を fail-fast
  - [x] CI でも `VIBE_CUTOVER_REQUIRED_FAIL_CLASSES=parse,type,io` を明示固定
  - [x] fail case 運用手順を `bench/selfhost_cutover/README.md` に文書化
- [x] Phase 3: Push/PR CI に cutover gate を追加する（定期実行なし）
  - [x] `scripts/test_selfhost_cutover_gate.sh` を追加（Phase 1/2 の検証を束ねる）
  - [x] `wasm-codegen-integrity` ジョブへ組み込み（parity 必須で fail-fast）
  - [x] `GITHUB_STEP_SUMMARY` に mode ごとの結果（pass/fail, bytes/hash）を出力
- [x] Phase 4: 実行デフォルトを selfhost 側へ切替する
  - [x] bootstrap gate の compile ステージを selfhost compiler (`moonrun`) 経由に切替（`VIBE_SELFHOST_CUTOVER=1` がデフォルト）
  - [x] rollback 用 env スイッチ: `VIBE_SELFHOST_CUTOVER=0` で host CLI 経路へ戻せる
  - [x] `$COMPILE_CMD` 変数で host/selfhost を切替（`run_stage` + `timeout` 互換）
- [x] Phase 5: MoonBit 依存を bootstrap 専用へ縮退する
  - [x] selfbuild gate の stage0 を `moon run --target wasm` から `moonrun` + pre-built wasm に切替
  - [x] MoonBit 側は自動ビルドフォールバック（wasm 未存在時のみ `moon build`）で保持
  - [x] 切替完了条件: bootstrap gate + selfbuild gate + cutover gate が全て green（selfhost 経路）

## WASM HTTP P3 Implementation (In Progress)

目標: `wasmtime serve -Sp3` で vibe の HTTP server handler を実行可能にする。

**ツールチェーン要件**: wasmtime >= 42.0.1, wit-bindgen >= 0.53.1, wac-cli >= 0.9.0

**解消済みブロッカー**:
- [x] `wasmtime serve` の `resource implementation is missing` エラー → wasmtime 42 + `-Sp3` フラグで解消 (2026-03-05)
- [x] service-only component の serve + e2e (HTTP 200 + body) → `scripts/probe_wasi_http_p3_service_only.sh`
- [x] adapter compose (vibe component + Rust adapter) の serve + e2e → `scripts/probe_wasi_http_p3_compose.sh`
- [x] blocked gate を strict mode (`VIBE_WASI_HTTP_P3_REQUIRE_READY=1`) + compose (`VIBE_WASI_HTTP_P3_RUN_COMPOSE=1`) で PASS

**Phase 1 (scalar-only, 完了)**:
- [x] Rust adapter: `import run: func() -> s64`, `export wasi:http/handler` をブリッジ
- [x] vibe fixture (`fixtures/http_p3_handler.vibe`): `run()` で status code 200 を返す
- [x] `wac plug` で compose → `wasmtime serve -Sp3` → HTTP 200

**Phase 2 (string params, 完了)**:
- [x] component codegen に string lift/lower (canon lift with memory + realloc) を追加
  - `emit_component_wasm_with_string_lift()`: trampoline module で canonical ABI flat (ptr, len) → vibe tagged string 変換
  - canon lift options: `0x00`=utf8, `0x03`=memory, `0x04`=realloc (component model binary spec 準拠)
  - trampoline に closure env (i32 0) パラメータを追加（vibe の export function は closure ABI）
  - `--component-string-lift` CLI フラグ + `compile_module_component_string_lift_auto()` で AST から string param を自動検出
- [x] adapter が vibe handler に request fields (method, url) を string で渡す
  - adapter WIT: `import handler: func(method: string, url: string) -> s64`
  - Rust adapter: `request.get_method()` / `request.get_path_with_query()` を extract
- [x] `force_cabi_realloc` で cabi_realloc 関数生成 + heap global 有効化を強制
- [x] e2e: request method/url に応じた動的 response を返す
  - `scripts/test_http_p3_string_e2e.sh`: compose + serve + curl (GET / → 200, GET /notfound → 404, POST / → 405)
- 既知制限: vibe の `==` 演算子は wasm backend で string 比較未対応（`string_equals()` builtin を使用）

**Phase 3 (本実装)**:
- [x] codegen: HTTP client builtins を `wasi:http/client.send` + resource 操作へ lower
  - combined adapter (Rust) が handler + client を一体化: handler returns -1/-2 → proxy GET/POST
  - `wac compose --no-validate` + binary patch (0x40→0x43) で async func type mismatch を回避
  - `futures::join!` で request/response stream を並行処理、`body_rx.collect()` で body 読み取り
  - `scripts/test_http_p3_client_e2e.sh`: direct + proxy e2e (5/5 PASS)
- [x] codegen: HTTP server builtins を `wasi:http/handler` export モデルへ再設計
  - P3 handler pattern: `export let handler = (method: String, url: String) -> Int`
  - old-style server builtins (`http_listen`, `http_accept`, `http_respond`) は P3 handler mode で明示エラー
  - `scripts/compose_http_p3_handler.sh`: vibe → component → adapter compose → serve-ready wasm を1コマンドで
- [x] component emit: handler export を持つ component を直接生成（adapter 不要化）
  - [x] prototype: `--component-string-lift --async` で async func type (0x43) を直接出力
  - [x] prototype: mwac に `ComponentFuncType.is_async` 追加（parse で 0x40/0x43 区別）
  - [x] `--compose-p3 --adapter <adapter.wasm>` CLI: compile → wac compose → async patch → validate を1コマンドで実行
  - [x] `compose_http_p3_handler.sh` を CLI ベースに更新（python3 binary patch 不要化）
  - [x] mwac compose で type section forwarding による合成（wac compose + binary patch の完全置き換え）
  - [ ] `wasi:http/handler` interface export を codegen で直接生成（resource/stream 対応が必要、将来課題）
- [x] runtime contract: interpreter/compiled でエラー契約を P3 経路でも一致
  - component_test: `component_string_lift_auto exports handler` + `interpreter returns correct status codes`
  - compile_wbtest: incompatible server builtins detection + compile error for mixed usage
- [x] e2e gate を CI (`wasm-codegen-integrity`) に追加
  - `scripts/test_http_p3_handler_gate.sh`: component validate + handler export + incompatible builtins rejection (8 checks)

**検証スクリプト**:
- `scripts/probe_wasi_http_p3_service_only.sh` — Rust のみの P3 service + e2e
- `scripts/probe_wasi_http_p3_compose.sh` — vibe + adapter compose + e2e (Phase 1: scalar)
- `scripts/test_wasi_http_p3_blocked_gate.sh` — 上記を束ねる gate
- `scripts/test_component_string_lift.sh` — Phase 2 infrastructure validation (exports + validate)
- `scripts/test_http_p3_string_e2e.sh` — Phase 2 e2e (string params + dynamic response)
- `scripts/test_http_p3_client_e2e.sh` — Phase 3 e2e (direct + proxy client)
- `scripts/compose_http_p3_handler.sh` — 1-command compose pipeline
- `scripts/test_http_p3_handler_gate.sh` — CI gate (component validate + export check + rejection)

## Self-Host WASM Codegen (vibe/compiler/ で .vibe → .wasm)

**目標**: selfhost コンパイラが自身を WASM にコンパイルできる真の完全セルフホスト

### P0: ブロッカー解消（codegen 着手の前提条件）✅

- [x] `fs_write_bytes(path, bytes)` builtin 追加
- [x] `ByteBuf` を .vibe で実装 — `Array[Int]` ベース + `bytes_from_array` で最終変換
- [x] LEB128 encoder を .vibe で実装

### P1: Core WASM codegen プロトタイプ ✅

- [x] WASM バイナリ構造の emit（magic + version + sections）
- [x] Type / Function / Code / Export / Memory / Data section
- [x] milestone: `let add = (a, b) -> a + b` が valid .wasm になる

### P2: 制御フロー + 関数呼び出し ✅

- [x] block/loop/br/br_if — if/else, while の codegen
- [x] call / call_indirect — 関数呼び出し + closure
- [x] local 変数割り当て — let / let mut の local index 管理
- [x] Global section — mutable global（heap pointer 等）
- [x] milestone: fibonacci, factorial が動く .wasm

### P3: データ型 + ランタイム ✅

- [x] tagged value encoding (62-bit int, string ref)
- [x] string operations — data section + runtime builtins
- [x] array / tuple — heap allocation + bump allocator
- [x] pattern match → nested br_if
- [x] Import section — WASI fd_write, builtins (print_int, string_*, array_*)
- [x] closures — lambda lifting, call_indirect, mutable capture (ref cells)
- [x] dual backend — codegen.vibe (linear memory) + codegen_gc.vibe (wasm-gc struct ref cells)
- [x] milestone: 101 codegen tests passing (wasmtime verified)

### P4: セルフコンパイル + Component Model

- [ ] selfhost の lexer.vibe が .wasm にコンパイルされ wasmtime で実行可能
- [ ] selfhost compiler 全体 (vibe/compiler/) が .wasm にコンパイルされ実行可能
- [ ] component_codegen を .vibe で再実装（core wasm → component binary wrap）
- [ ] mwac plug 相当を .vibe で実装 or builtin 化（adapter compose）
- [ ] milestone: selfhost compiler 全体が .wasm component として動作

### 現在の .vibe 言語の制約と回避策

| 制約 | 影響 | 回避策 |
|------|------|--------|
| `~` (bit_not) 非対応 | ビット反転 | `x ^ 0x7FFFFFFFFFFFFFFF` で代用 |
| mutable closure 制限 | CodegenCtx 的な状態管理 | レコード + 関数引数で明示受け渡し |
| mwac/wite は MBT パッケージ | .vibe から直呼び不可 | P4 で対応 |

## Blocked / External

- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応

## Deferred

- [ ] `wasi:http/handler` interface export を codegen で直接生成（P4 の先、resource/stream/future 40+ 型）
