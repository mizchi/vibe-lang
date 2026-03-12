# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## vibe/x 準公式ライブラリ拡充

Phase 1 (基盤):
- [ ] x/fmt — printf 風文字列フォーマット (`format("{} is {}", [s("hello"), i(42)])`)
- [ ] x/url — URL パース・クエリ文字列エンコード/デコード
- [ ] x/uuid — UUID v4 生成 (random ベース)

Phase 2 (DX):
- [ ] x/color — ANSI カラー出力 (red, green, bold 等)

Phase 3 (機能):
- [ ] x/regexp — 正規表現 (NFA ベース)
- [ ] x/toml — TOML パーサー

Phase 4 (応用):
- [ ] x/template — 簡易テンプレートエンジン (`{{variable}}` 置換)
- [ ] x/semver — セマンティックバージョニングのパース・比較
- [ ] x/diff — テキスト差分 (Myers diff)

## Language/Stdlib Proposals (AI-first authoring)

- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Self-Host Compiler / Runtime Packaging

**現状**: compiler API export、統合 compile pipeline、module loader、selfhost source manifest、bundle drift check、TypeDb cache probe、selfhost CLI batch cache、host CLI の check/test loop cache 再利用、env/argv 契約、stage1 core wasm 直接の artifact-only compile gate、Preview2 component-only selfhost CLI gate、Preview2 package、command world 配布 gate、direct fs/argv component 配布 gate、strict-recursive selfbuild 復帰まで入った。`stage1 artifact 自体で sample を compile して run=42` と `just test-selfhost-wasi-selfbuild-kpi 300` の strict-recursive mode は通る。
**最優先の残**: MoonBit host CLI を bootstrap 専用へ縮退し、selfhost 配布形を `check/test/release-check` の本流へ寄せること。そのうえで typed Preview2 import と perf gap を詰める。

### Selfhost compiler modularization / cache

- [x] strict-recursive selfbuild regression を解消する
  - `selfbuild_runtime_entry.vibe` を lean stage2 runtime target に切り出し、`selfbuild_runtime_entry_bundle.vibe` から source を読む形にした
  - `selfbuild_compile_stage2` は grouped source compile ではなく `compile_source_wasi_only(..., "selfbuild_entry")` で stage2 target を直接焼く
  - `just test-selfhost-wasi-selfbuild-kpi 300` は strict-recursive mode で `recursive=1`, `total=11s`, `stage2_run=0` に復帰した

- [ ] MoonBit host CLI を bootstrap 専用へ縮退する
  - selfhost 配布形は Preview2 package / command component / direct fs/argv component まで揃ったが、`check/test/release-check` の本流はまだ `src/cmd/vibe` に残っている
  - selfhost direct fs component と host compile を並走させる dual-compile smoke gate は追加済み
  - selfhost check 配布形も Preview2 package / command component / direct fs component まで揃い、`release-selfhost-gates` に smoke gate を追加した
  - 次は selfhost command/direct component を host CLI の一部フローへ差し込み、dual-run 対象を `check/test/release-check` へ広げながら切り替える
  - `test_selfhost_check_parity.sh` も最終的には component 配布形へ寄せ、`moonrun "$STAGE1_CHECKER_WASM"` 依存を bootstrap 専用へ押し込む

- [ ] selfhost perf gap を cutover 可能な水準まで詰める
  - stable 5-case set の debug selfhost wasm baseline では host 比 compile 約5x、check 約2-4x 遅い
  - `VIBE_SELFHOST_PERF_WASM_PROFILE=release` でも計測できるようにしたが、現状は `base64` compile が大きく悪化するため KPI default はまだ debug baseline に置いている
  - `vibe/compiler/index.vibe` は compile-lite の unsupported closure capture path をまだ踏むため、perf KPI default からは外して別測定にしている
  - grouped merge / module source / codegen cache は入っているので、次の本命は typecheck / codegen hot path の profiling と削減
  - 直近の hotspot は `check/type` と `compile/compile` で、stable set の stage summary を `scripts/bench_selfhost_perf.sh` が出せるようにした
  - `compile/write` も比率は極端だが絶対時間は数 ms〜30 ms 台なので、まずは `check/type` と `compile/compile` を削る

- [x] host `src/cmd/vibe` 側の compile/test loop にも selfhost と同じ persistent cache パターンを持ち込む
  - `src/loader` に `*_into` API を追加し、`check_cmd` / `test_cmd_sequential` / `test_cmd_report_json` が root 単位 `VibeDb` cache を持ち回るようにした
- [x] selfhost compiler の module fingerprint cache を typecheck 再利用から codegen/link まで拡張する
  - `TypeDb` に dependency source / merged source / final artifact cache を持たせ、warm compile で typecheck / parse / merge / codegen の再実行を避ける
  - `compile_with_modules_cached` / `compile_file_fs*_cached` は fingerprint 一致時に cached wasm bytes を返す
  - strict-recursive selfbuild KPI に `codegen_cache_count1/2` を追加し、stage1 artifact 上でも warm codegen reuse を確認できるようにした
- [x] selfhost compiler の artifact cache を entry 間共有まで一般化する
  - final artifact cache の key を path 依存から外し、artifact fingerprint を `program_source` / `merged_source` ベースに寄せた
  - 同一 source を別 entry path からコンパイルしても warm codegen が再実行されない形にした
- [x] selfhost compiler の module fingerprint cache を merged/lowered artifact reuse まで一般化する
  - merged source cache は fingerprint ベースで別 entry 間共有まで入った
  - module source cache も fingerprint ベースで別 entry 間共有にし、codegen 手前の parse/lower をさらに減らした
- [x] selfhost compiler の grouped source compile を embedded adapter closure にも適用する
  - `selfhost_cli_adapter_sources` / `selfhost_cli_adapter_source_groups` を導入し、adapter 専用 closure を compiler 全量 source から切り離した
  - stage1 probe で adapter closure は `68 sources / 9 groups -> 24 sources / 5 groups` まで縮小できている
- [x] `compile_wasi_module` 前に selfhost DCE を差し込み、entry 未到達定義を codegen しない経路を作る
  - `core/dce.vibe` を新設して `dce_stmts` を core layer に寄せ、closure/grouped compile の両方で `prune_entry_stmts` を通すようにした
  - `compiler_cache_test.vibe` に unreachable broken def を codegen 前に落とす回帰を追加した
- [ ] `vibe/compiler` の論理分割を manifest `group` 列に合わせて進める
  - 候補: `core/`, `syntax/`, `checker/`, `codegen/`
  - 目的はディレクトリ整理そのものではなく、manifest と cache 単位を一致させること
  - `module_loader` には manifest group を保った `collect_source_groups_fs` を追加済み
  - `compiler` の FS compile path も grouped merge cache を通すようにした
  - 物理分割は `core/ast.vibe` から着手し、旧 `ast.vibe` は wrapper で互換維持している
  - `syntax/token.vibe` / `syntax/float_format.vibe` / `syntax/lexer.vibe` / `syntax/parser.vibe` / `syntax/printer.vibe` を新設し、旧 root file は wrapper で互換維持している
  - `core/types.vibe` と `checker/builtins.vibe` / `checker/checker_resolve.vibe` / `checker/checker_pattern.vibe` / `checker/checker.vibe` / `checker/checker_stmt.vibe` を新設し、旧 root file は wrapper で互換維持している
  - `core/bytebuf.vibe` と `codegen/wasm_emit/index.vibe`, `codegen/common_base/index.vibe`, `codegen/common_extractors/index.vibe`, `codegen/common_analysis/index.vibe` を新設し、旧 root file は wrapper で互換維持している
  - `codegen_expr.vibe` / `codegen_builtin_bodies.vibe` / `codegen_wasi.vibe` / `codegen_gc.vibe` は `codegen/*/index.vibe` へ移し、旧 root file は wrapper で互換維持している
  - `runtime/eval_loader/index.vibe`, `runtime/index.vibe`, `loader/index.vibe`, `entry/compiler/index.vibe`, `entry/cli_cache/index.vibe` を新設し、旧 root file は wrapper で互換維持している
  - 残りは public hub の `index.vibe` をどこまで薄くするかと、root wrapper をいつ整理するかの判断
### Selfhost CLI / I/O boundary

- [x] selfhost CLI の責務を「純粋 compile 関数」までに固定するか、WASI I/O まで selfhost 側に持ち込むかを文書化する
  - ADR-0022: selfhost compiler は pure compile API に留め、filesystem / environ / stdio は `vibe_compile_wasi` など host wrapper 側で扱う
- [x] Preview2 host 付きで selfhost artifact を実行する導線を作る
  - stage1 用 wrapper source を `--wasm --force-cabi-realloc` で core wasm 化し、`node scripts/wasm_vibe_host_runner.js` に Preview2 filesystem import 実装を足して実行できるようにした
  - stage1 selfhost compiler は seed compiler で一度だけ生成し、その後は JS host が Preview2 filesystem を供給して artifact-only で走らせる
- [x] stage1 selfhost compiler artifact だけで実ファイル compile を通す artifact-only gate を持つ
  - `scripts/test_selfhost_cli_adapter.sh` は `stage1 core wasm -> selfbuild_cli_args_entry -> sample wasm compile -> sample run=42` を確認する
- [x] selfhost CLI adapter を env-driven に一般化する
  - `VIBE_INPUT` / `VIBE_OUTPUT` / `VIBE_ENTRY` を読む `selfhost_cli_adapter.vibe` と `scripts/test_selfhost_cli_adapter.sh` が通る
  - `scripts/wasm_vibe_host_runner.js` は host-only string arena を持ち、`Env::get` の戻り string が後続 allocation で壊れない
- [x] selfhost CLI adapter に argv 契約を追加する
  - `scripts/run_wasm_vibe_host_runner.sh <wasm> <input> <output> <entry>` で位置引数を `VIBE_INPUT` / `VIBE_OUTPUT` / `VIBE_ENTRY` へ写し、env-driven adapter をそのまま CLI 契約として使える
- [x] selfbuild direct gate は env / argv の両契約で通る
  - `selfbuild_cli_env_entry` / `selfbuild_cli_args_entry` の両方で sample compile と output wasm 実行が通る
- [ ] stage1 selfhost compiler artifact から standalone selfhost CLI adapter wasm を安定生成する
  - これは direct gate 後の任意最適化に降格した
  - `selfbuild_write_cli_adapter` は `selfhost_cli_adapter_sources` の grouped closure を使うようにした
  - `selfhost_cli_adapter_merged_source` は exact flat source としては不正（duplicate declaration を含む）と判明したため、`module_source` 経由で valid module text を作る経路へ寄せている途中
  - 直近の blocker は `db_module_source` / `compile_with_source_groups_via_module_source_wasi_unchecked_cached` が stage1 artifact 上でまだ重いこと
- [x] JS host 依存を外し、Preview2 / Component runtime だけで selfhost artifact を CLI として閉じる
  - `selfhost_cli_component_entry.vibe` は `compile_cli_request(source, request)` を string-lift component export として公開し、`len:<entry>` / `chunk:<entry>:<index>` 契約で compiled wasm bytes を段階取得できる
  - `scripts/test_selfhost_cli_component_preview2.sh` は wasmtime Preview2 のみで component を実行し、復元した sample wasm の `run=42` まで確認する
  - direct `fs/env` component import を無理に入れず、request/response 契約へ寄せて JS host / Node runner 依存を外した

### Component Model / Adapter Compose

- [ ] mwac plug 相当を .vibe で実装するか builtin 化する
- [x] selfhost compiler 全体を `.wasm` component として配布・実行できる形にする
  - `scripts/build_selfhost_cli_preview2_component.sh` で selfhost component/WIT を build し、`scripts/run_selfhost_cli_preview2_component.sh` が `compile-cli-request` 契約を使って input file -> output wasm を復元する
  - `scripts/test_selfhost_cli_preview2_package.sh` は package build -> sample compile -> wasm validate -> run=42 を固定する
- [x] selfhost CLI の package surface を command world に一般化する
  - `scripts/build_selfhost_cli_command_component.sh` は `compile-cli-hex(source, entry-name)` を import する Preview2 command adapter component を組み立てる
  - `scripts/test_selfhost_cli_command_component.sh` は stdin=source / argv[-1]=entry / stdout=wasm の command world で sample compile -> wasm validate -> run=42 を固定する
  - `release-selfhost-gates` に `test-selfhost-cli-preview2-package` と `test-selfhost-cli-command-component` を接続し、配布形の gate を pre-release 導線へ載せた
- [x] selfhost CLI の package surface を direct fs/argv component に一般化する
  - `selfhost_cli_direct_component_entry.vibe` は `compile-cli-hex(source, entry-name)` だけを export する専用 plug component として build できる
  - `scripts/build_selfhost_cli_direct_component.sh` はその plug component を Preview2 filesystem adapter component と compose し、`run-cli-request(input-path, output-path, entry-name)` surface を配布可能にした
  - `scripts/test_selfhost_cli_direct_component.sh` は input file -> output wasm -> run=42 を direct fs/argv gate として固定し、`release-selfhost-gates` に接続した
- [x] selfhost check の package surface を Preview2 package / command / direct fs component に広げる
  - `selfhost_check_component_entry.vibe` は `check-source-report(source)` を export する string-lift component entry として build できる
  - `scripts/test_selfhost_check_preview2_package.sh` は Preview2 component を直接 invoke して `ok` / `error:<msg>` の report contract を固定する
  - `scripts/test_selfhost_check_command_component.sh` は stdin=source / stdout=report / exit code=success-fail の command world gate を固定する
  - `scripts/test_selfhost_check_direct_component.sh` は input file -> output report file の direct fs gate を固定し、`release-selfhost-gates` に接続した
- [ ] string-lift component の direct Preview2 import surface を typed world にする
  - `selfhost_cli_component_run_entry.vibe` 自体は `run-cli-request(input-path, output-path, entry-name)` component まで生成できる
  - ただし top-level component import は `import-0..5` の flat ABI に潰れており、wasmtime linker が Preview2 `wasi:filesystem/*` 実装へ自動結線できない
  - 現状は `compile-cli-hex` 専用 plug component + filesystem adapter component の compose で direct fs/argv 配布を実現している
  - 次の本命は `emit_component_wasm_with_string_lift` 側で typed Preview2 import を持つ import/adapter 生成へ寄せること

## Release / Gate Integration

- [ ] selfhost bootstrap の heavy shard をさらに削る
  - 進捗ログ、file 単位 batch、`selfhost_test_batch_weights.seed.json` の refresh 導線、`parser` / `stmt` / `printer` / `fixture` / `eval` / `eval_stmt` / `eval_selfhost` / `eval_selfhost2` / `eval_selfhost3` / `type_db` / `eval_e2e` / `checker_stmt` / `checker` / `cst_lower` の分割までは入った
  - refresh helper は bootstrap cache の実 path (`_build/bench/selfhost_bootstrap/...`) に追従済み
  - `selfhost_s5_*` と `codegen_parser_test` は compiled bootstrap から外し、別導線で扱う前提に寄せた
  - bootstrap 先頭 batch は 88 files まで分散済み
  - printer 系は `printer_function_test` / `printer_literal_test` / `printer_block_test` / `printer_operator_test` / `printer_call_test` / `printer_loop_test` / `printer_effect_test` まで分割済み
  - `stmt_decl_test` は import/use、data 宣言、type 宣言に分割済み、`cst_lower_expr_test` も literal/ops・binding/call・controlflow に分割済み
  - `parser_test` は operator/function/literal へ分割済み、`parser_controlflow_test` / `parser_destructure_test` は loop / invalid keyword まで分離済み
  - `fixture_selfhost_test` は parse / roundtrip に分割済み
  - `stmt_fn_regression_test` は `stmt_fn_tuple_regression_test` に、`fixture_test` は parse / roundtrip に分割済み
  - direct compiled 実測で重い候補は `compiler_test`、`stmt_regression_test`、`checker_stmt_regression_test`、`parser_flow_test`、`codegen_lexer_test`
  - 次の実作業候補: `stmt_regression_test` / `checker_stmt_regression_test` の再分割、`compiler_test` の compile_source 系を独立 file に切り出す
- [ ] compiled bootstrap から外した重い回帰ケースの扱いを固定する
  - `codegen_parser_test` は release binary でも 240s で完走しないため、専用 gate か fixture 化に寄せたい
  - `selfhost_s5_*` は selfbuild / artifact gate と責務が重複しているので、compiled bootstrap では走らせない前提を文書化したい
- [ ] `vibe_normalize_all` の explicit exclude を外す
  - 現状 `vibe/compiler/coverage_selfhost_suite_lib.vibe` は native normalize crash 回避のため batch 対象から外している
  - normalize engine 側の crash を直して exclude なしで回したい

## Migration Cleanup

- [ ] `map_builder*` 互換 alias を削除する条件を固める
  - 条件案: docs と eval task の canonical 化完了、rename script の dry-run 実績、host/selfhost の alias coverage を維持したまま deprecation 期間を決める
  - 対象: host checker/runtime/codegen の互換層、selfhost builtin 正規化、alias 専用 wbtest

## ユーザビリティ改善

### 高優先度（日常的な不便）

- [x] `==` で String/値比較（既に動作していた。examples を `==` スタイルに更新済み）
- [x] Map 操作のビルトイン化: `Map::set(m, key, value)` 追加、`Map[K, V]` ジェネリック化、Hash トレイトバウンド
- [ ] メソッド構文の導入（`s.length()` 等。現状すべてフリー関数で `String::length(s)` が必要）

### 中優先度（ボイラープレート削減）

- [ ] 空 Map リテラル `map {}` のサポート
- [ ] Array スプレッド構文 `[...xs, new_item]`（ArrayBuilder::new 3ステップの簡略化）
- [ ] トレイトにメソッド定義を許可（現状マーカーのみ。ユーザー定義型の `Eq` 実装不可）
- [ ] `?` 演算子または `try` 式（`handle { ... } { Error(_) => ... }` のネスト軽減）

### 低優先度（構文・ツール）

- [ ] `export` ブロック重複の lint/warning
- [ ] ドキュメントコメント構文（`///` 等）
- [ ] `for-in` の accumulate パターン改善（fold 的な構文糖衣）

## 現在の .vibe 言語の制約と回避策

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
