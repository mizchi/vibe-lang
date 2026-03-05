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

## Blocked / External

- [ ] WASM HTTP builtins の本実装（現状は wasm で catchable fallback error）。WASI P3 HTTP (`wasi:http@0.3.0-draft`) 安定待ち
  - Client: `wasi:http/client.send` で outgoing request 送信
  - Server: `wasi:http/handler` export で incoming-request 受信 (wasmtime serve)
  - [ ] Adapter compose ツールチェーンを P3 async 対応へ更新する（現状ブロッカー）
    - `wit-bindgen 0.51` + `wasm-tools component new` で作った service-only component（compose なし）でも `wasmtime serve` が `resource implementation is missing` で失敗する
    - `wac-cli 0.9.0` では `plug + validate` は通るが、`wasmtime serve` で `wasi:http/types` resource 実装不一致（`resource implementation is missing`）により起動できない
    - `mwac/wite compose` は同入力で `unknown type ... type index out of bounds` となり invalid component を出力する
    - `wasm-tools compose` は function import (`run`) 経路で panic するため、現行では直列 compose の代替にならない
    - 外部 issue:
      - wasmtime: https://github.com/bytecodealliance/wasmtime/issues/12714
      - wit-bindgen: https://github.com/bytecodealliance/wit-bindgen/issues/1554
    - 再現スクリプト:
      - `scripts/build_wasi_http_p3_adapter.sh`（P3 adapter build）
      - `scripts/probe_wasi_http_p3_compose.sh`（app component build + `wac plug` + `wasmtime serve` smoke）
      - `scripts/probe_wasi_http_p3_service_only.sh`（service-only build + `wasmtime serve` smoke）
      - `scripts/test_wasi_http_p3_blocked_gate.sh`（blocked/strict gate。`VIBE_WASI_HTTP_P3_REQUIRE_READY=0` なら既知ブロッカーを許容）
  - 実装タスク（vibe 側）:
    - [ ] codegen: HTTP client builtins (`http_request` / `http_response_*` / `http_close`) を `wasi:http/client.send` + `wasi:http/types` resource 操作へ lower
      - [x] component compile 経路（`--component --http-host-imports`）の client import 名を `wasi:http/client@0.3.0-draft` / `wasi:http/types@0.3.0-draft` shim へ切り替え（`send` / `response-*` / `[drop]response`）
      - [ ] server builtin 分は現状 `vibe:http/*` のまま（`wasi:http/handler` export 実装まで据え置き）
      - [ ] resource 本体（`types.request` / `types.response`）を使う実 lower は未実装（現状は i64 handle shim ABI）
    - [ ] codegen: HTTP server builtins (`http_listen` / `http_accept` / `http_request_*` / `http_respond`) を `wasi:http/handler` export モデルへ再設計（listen/accept API との対応を確定）
      - [x] component WIT 生成で server builtin 使用時は `wasi:http/handler` を import ではなく export として出力
    - [ ] component emit: HTTP server builtin 使用時に `wasi:http/handler` export を持つ component を生成（現状は WIT 契約のみ）
    - [ ] runtime contract: interpreter/compiled でエラー契約（`Io(op=...)`, `PermissionDenied: net_*`）を P3 経路でも一致させる
    - [ ] e2e gate: `wasmtime serve` で request -> handler -> response の往復を CI で検証
  - 実装前提（vibe 側）:
    - [x] host import で String を返すための guest allocator/export 契約を定義
      - wasm codegen が `vibe_http_host_string_new(i32)->i64` を export（`--http-host-imports` + HTTP builtin 使用時）
      - host は `memory` に UTF-8 bytes を書き込み、tagged string (`i64`) を返せることを e2e で検証
    - [x] compiled 実行系（`vibe run/test`）で `vibe:http` host runtime を提供（`scripts/wasm_http_host_runner.js` を使用）
    - [x] capability allowlist を compiled host runner 側へ統合（`VIBE_HTTP_ALLOW_CONNECT`, `VIBE_HTTP_ALLOW_LISTEN`）
      - `can_connect_any` / `can_listen_any` 判定は interpreter 契約に一致（該当 capability が1つでもあれば許可）
      - deny/allow の回帰を `scripts/test_compiled_backend_http_policy.sh` に追加
- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応

## Deferred

- none
