# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## vibe/x 準公式ライブラリ拡充

Phase 1 (基盤):
- [x] x/fmt — printf 風文字列フォーマット: 実装済み (24/24 pass)
- [ ] x/url — URL パース: 実装済みだが compiled test で `../regexp` import がルート外エラー
  - `pattern.vibe` が `import ../regexp` で兄弟モジュールを参照。テストランナーの root 制約を緩和するか、regexp を url 内にコピーする必要あり
- [x] x/uuid — UUID v4 生成: 実装済み (11/11 pass)

Phase 2 (DX):
- [x] x/color — ANSI カラー出力: 実装済み (15/15 pass)

Phase 3 (機能):
- [ ] x/regexp — 正規表現: 実装済み、compiled backend で 72/91 pass (19 fail)
  - 失敗: character class (`[abc]`)、capture group、find_all/replace_all/split 関連
  - 原因: `compile("[a]")` の結果を cross-module で destructure すると tuple 中身が破壊される
  - interp mode では全 pass。compiled backend のヒープ管理バグ（if/else heap_synced leak と同根）
- [ ] x/toml — TOML パーサー: 実装済み、compiled backend で 14/28 pass (14 fail)
  - `[]` 型推論エラーは修正済み (0/28 → 14/28)
  - 残り 14 件は x/regexp と同根の compiled backend バグ

Phase 4 (応用):
- [ ] x/template — 簡易テンプレートエンジン (`{{variable}}` 置換)
- [ ] x/semver — セマンティックバージョニングのパース・比較
- [ ] x/diff — テキスト差分 (Myers diff)

## Language/Stdlib Proposals (AI-first authoring)

- [ ] language: tolerant parser（壊れた途中コードを AST 化して保持）
  - vibe shell での書き散らしを最後に normalize 可能にする
- [ ] language: AST rewriter / macro API（構文正規化パスを定義可能にする）
  - desugar/normalize を言語内で記述し、自己ホスト実装を縮小

## Vibe 言語仕様の整合性

言語設計者視点での未整理項目。実装の局所修正ではなく、AST / 型 / 構文 / evaluator / checker の契約を仕様として揃える前提で扱う。

- [ ] function type / effect 表現を AST・型・parser・printer・checker で統一する
  - 現状は `TyFn` に effect がなく、`CtFn` は `Bool`、`EFn` は `Option[String]` で別表現になっている
  - `EffectSet` か effect row を一次表現にして、`spec/decisions.md` に固定する
- [ ] selfhost evaluator の AST codec を full-fidelity にする
  - `EFn` の type params / bounds / return type / effect、`break` payload、`continue(args)` payload が encode/decode で落ちている
  - closure 保存用の専用 IR に寄せるか、AST codec を完全往復可能にする
- [ ] method syntax を nominal sugar と trait dispatch のどちらにするか仕様として固定する
  - 現状は `obj.method(x)` を `Type::method(obj, x)` へ文字列ベースで落としており、generic receiver や trait method の規則が曖昧
- [ ] import surface の kind 情報を AST に残す
  - `import { type X }` / `import { trait Y }` を parser は受理するが AST で kind を捨てている
  - `ImportItemKind` と typed `ModuleRef` を導入し、module system の仕様を固める
- [ ] 演算子の型規則を checker と evaluator で一致させる
  - 現状は checker が非 bool 二項演算をほぼ `Int` 扱いし、evaluator は `Float` と `String` の overload を持つ
  - `+ - * /` と比較演算の overload を仕様に落としてから両実装を揃える
- [ ] 文字列補間を raw source 再 parse ではなく typed AST にする
  - `EStringInterp(Array[String])` は lossy で、expand 時に再 lex/parse している
  - `Lit(String) | Expr(Expr)` の補間パーツへ変更し、parser が式まで責任を持つ
- [ ] `loop` / `continue` の状態受け渡しを positional から named へ寄せる
  - 現状の `EContinue(Array[Expr])` は `ELoop(Array[(String, Expr)], ...)` と契約がずれており、将来の拡張に弱い
  - `continue(x = ..., y = ...)` 相当の AST にして merge 規則を明文化する
- [ ] generic `impl` を AST だけ先行させる状態を解消する
  - parser は `impl type parameters are not supported yet` で落とす一方、AST には generic `SImpl` がある
  - 今すぐやらないなら AST から落とし、やるなら parser/checker/eval/codegen まで一気通しで揃える

## Self-Host Compiler / Runtime Packaging

**現状**: compiler API export、統合 compile pipeline、module loader、selfhost source manifest、bundle drift check、TypeDb cache probe、selfhost CLI batch cache、host CLI の check/test loop cache 再利用、env/argv 契約、stage1 core wasm 直接の artifact-only compile gate、Preview2 component-only selfhost CLI gate、Preview2 package、command world 配布 gate、direct fs/argv component 配布 gate、strict-recursive selfbuild 復帰まで入った。`stage1 artifact 自体で sample を compile して run=42` と `just test-selfhost-wasi-selfbuild-kpi 300` の strict-recursive mode は通る。
**最優先の残**: MoonBit host CLI を bootstrap 専用へ縮退し、selfhost 配布形を `check/test/release-check` の本流へ寄せること。そのうえで typed Preview2 import と perf gap を詰める。
**一時メモ**:
- selfhost coverage suite aggregate は raw `id` ではなく `span.start-end` union に直し、warm rerun でも summary が安定する状態まで戻した
- coverage 側に戻るときの次の入口は `eval_e2e_test.vibe` の branch gap を詰めること
- その次は、coverage 拡張ではなく selfhost cutover 本体として `check/test/release-check` をどの配布形から差し替えるかを固定する
- `just test-selfhost-cutover` と `just test-selfhost-wasi-selfbuild-kpi 300` の回帰は復旧済み
- compiled selfhost shard 2/4 の blocker だった `eval_e2e` の string interpolation、`checker_unify` の `CtForAll` 対称 unify、fixture selfhost の root 外 import、`monoify` の selfhost type error は解消済み
- compiled selfhost shard 2/4 は root-affine batch 後の成功条件で `28 files / 10 batches / 281 tests / real 101.67s` を確認済み
- parallel test wrapper の child stdout/stderr decode は lossy に修正し、compiled shard 1/4 で出ていた `invalid JSON report` の誤検知経路は潰した
- compiled selfhost shard 1/4 は `module_loader_test` / `file_compile_mode_test` を含む 2 batch が支配しており、成功条件の確定前でも `13m+` 張り付きで bootstrap 全体の最重 shard 候補になっている
- `selfhost_test_batch_weights.seed.json` に `module_loader_test` / `file_compile_mode_test` / `codegen_test` / `codegen_controlflow_test` の seed を補正し、preview 上は shard 1/4 の batch 1/10, 2/10 で `module_loader_test` と `file_compile_mode_test` を singleton 化できた

### Selfhost compiler modularization / cache

- [x] strict-recursive selfbuild regression を解消する
  - `selfbuild_runtime_entry.vibe` を lean stage2 runtime target に切り出し、`selfbuild_runtime_entry_bundle.vibe` から source を読む形にした
  - `selfbuild_compile_stage2` は grouped source compile ではなく `compile_source_wasi_only(..., "selfbuild_entry")` で stage2 target を直接焼く
  - `just test-selfhost-wasi-selfbuild-kpi 300` は strict-recursive mode で `recursive=1`, `total=11s`, `stage2_run=0` に復帰した

- [ ] MoonBit host CLI を bootstrap 専用へ縮退する
  - selfhost 配布形は Preview2 package / command component / direct fs/argv component まで揃ったが、`check/test/release-check` の本流はまだ `src/cmd/vibe` に残っている
  - selfhost CLI command component の dual-run smoke gate を追加し、source-text compile surface については host CLI と selfhost 配布形を `release-selfhost-gates` で並走できるようにした
  - command component parity は `mvp/no-dce` の両 mode まで拡張済みで、source-text compile-lite の既定比較は command/direct の両配布形で取れる
  - selfhost direct fs component と host compile-lite を並走させる dual-compile smoke gate は `mvp/no-dce` の両 mode まで追加済みで、runner も input/output staging を吸収する
  - selfhost cutover compare も `compile` から `compile-lite` ベースへ移し、artifact parity の既定 mode は `mvp,no-dce` に寄せた
  - selfhost check 配布形も Preview2 package / command component / direct fs component まで揃い、command component parity を含む smoke gate を `release-selfhost-gates` に追加した
  - ただし current direct fs component は source-text compile surface なので、relative import を含む full file parity はまだ `moonrun "$STAGE1_COMPILER_WASM" compile-lite` 側に残る
  - full file parity 用の groundwork として `compile_file_fs_mode_cached(..., mode)` は追加済みで、file/import 閉包側にも `mvp/no-dce` を持ち込めるようにした
  - 次は file/import 閉包を含む compile-lite surface を selfhost component 側に持ち込むか、先に command/package 形で `check/test/release-check` の本流を段階的に selfhost 配布形へ差し替える
  - `test_selfhost_check_parity.sh` は `test-selfhost-check-bootstrap-parity` として bootstrap-only target に退避し、`release-selfhost-gates` からは component smoke 系だけを残した
  - `release-selfhost-bootstrap-gates` を追加し、stage1/stage2 artifact health と full checker parity の入口を bootstrap 専用 bundle に分離した
  - full diagnostic parity 自体はまだ `moonrun "$STAGE1_CHECKER_WASM"` に依存するので、将来的に component 側で type diagnostics を返せるようになった段階で置き換える

- [ ] selfhost perf gap を cutover 可能な水準まで詰める
  - stable 5-case set の debug selfhost wasm baseline では host 比 compile 約5x、check 約2-4x 遅い
  - `compile-lite --profile-tsv` は `compile_module` / `bundle` / `emit` / `optimize` まで細粒度で出すようにした
  - 直近の stable 5-case run では TOTAL が compile `3.20x`, check `5.07x`。特に `module_import.vibe` の `check/type`、`module_export.vibe` の `check/type`、`base64.vibe` の `compile/optimize` が突出している
  - `VIBE_SELFHOST_PERF_WASM_PROFILE=release` でも計測できるようにしたが、現状は `base64` compile が大きく悪化するため KPI default はまだ debug baseline に置いている
  - `vibe/compiler/index.vibe` は compile-lite の unsupported closure capture path をまだ踏むため、perf KPI default からは外して別測定にしている
  - grouped merge / module source / codegen cache は入っているので、次の本命は typecheck / codegen hot path の profiling と削減
  - 直近の hotspot は `check/type` と `compile/emit` / `compile/bundle` を含む compile substage で、stable set の stage summary を `scripts/bench_selfhost_perf.sh` が動的 stage 集計で出せるようにした
  - `compile/write` と `compile/optimize` は比率が極端でも絶対時間が小さいケースがあるので、まずは `check/type` と `compile/emit` を削る
  - persistent dep cache の parse-count probe は `fresh db` 2回目を `6 -> 0` まで下げたが、wall time はまだ process cold start と import closure 解析が支配している
  - `just bench-selfhost-cache-probe` を追加し、`TypeDb fs multi-dep` と `CLI prepare batch shared TypeDb` の専用 probe を常設した
  - 次にやること:
    - `vibe test` / bootstrap shard の child process 分割を減らし、同じ root を同一 worker に寄せて `CliEntryDbCache` / shared `TypeDb` の hit 率を上げる
    - `prepare_jobs_cached` で入れた sibling 共有を、実際に重い bootstrap/test の selfhost compiled 経路へ直接適用する
    - dep list cache の次段として `header/interface` を永続化し、fresh process でも import closure discovery の CPU を落とす
    - root-affine batch 後の compiled selfhost shard 1/4, 3/4, 4/4 を同条件で再計測し、bootstrap 全体の支配 shard を確定する
    - `just test-selfhost-bootstrap` を再開し、timeout ではなく実 wall time / failure point を現行 tree で採り直す
    - shard 1/4 については、まず `module_loader_test` と `file_compile_mode_test` を含む batch を個別導線へ逃がすか、さらに file 単位で分解するかを決める

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
  - ADR-0028: selfhost compiler は pure compile API に留め、filesystem / environ / stdio は `vibe_compile_wasi` など host wrapper 側で扱う
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
  - root-affine batch で child process 数は `28-32 -> 10` まで減らせたが、wall time の再計測は shard 2/4 しか終わっていない
  - shard 1/4 は `printer_loop + cst_lower_expr_binding + codegen_controlflow + file_compile_mode + codegen` と `stmt_data_decl + module_loader + types` の 2 batch が 13 分超で張り付き、現時点ではここが bootstrap 最重候補
  - seed 補正後の preview では `module_loader_test` と `file_compile_mode_test` は singleton batch に分離できたので、次はこの seed で shard 1/4 の wall time を採り直す
  - 次は shard 1/4, 3/4, 4/4 を同条件で取り直し、分割で解決する問題か、個別 test 最適化へ進むべきかを確定する
- [ ] compiled bootstrap から外した重い回帰ケースの扱いを固定する
  - `codegen_parser_test` は release binary でも 240s で完走しないため、専用 gate か fixture 化に寄せたい
  - `selfhost_s5_*` は selfbuild / artifact gate と責務が重複しているので、compiled bootstrap では走らせない前提を文書化したい
- [ ] `just release-check` を selfhost 復旧後の現行 tree で最後まで通す
  - 直近では bootstrap shard の重さを優先して後回しにしている
  - 残りは bootstrap 全体の再計測、通過確認、その上で `release-check` の再実行
- [ ] `vibe_normalize_all` の explicit exclude を外す
  - 現状 `vibe/compiler/coverage_selfhost_suite_lib.vibe` は native normalize crash 回避のため batch 対象から外している
  - normalize engine 側の crash を直して exclude なしで回したい

## Migration Cleanup

- [ ] `map_builder*` 互換 alias を削除する条件を固める
  - 条件案: docs と eval task の canonical 化完了、rename script の dry-run 実績、host/selfhost の alias coverage を維持したまま deprecation 期間を決める
  - 対象: host checker/runtime/codegen の互換層、selfhost builtin 正規化、alias 専用 wbtest
- [x] `vibe/` 全体を現行構文へ寄せる（第一段階）
  - [x] `String::equals(a, b)` → `a == b`: 1600+ 箇所 / 154 ファイル置換済み
  - [x] `String::concat(a, b)` → `"\{a}\{b}"` 文字列補間: 1000+ 箇所 / 89 ファイル置換済み（パイプ演算子使用の 31 箇所は残留）
  - [-] `Array::slice([dummy], 0, 0)` → `[]`: 不可。`[]` は常に `Array[Unit]` に型推論されるため、型付き空配列リテラル構文が必要
  - [-] `Type::method(obj, ...)` → `obj.method(...)`: 不可。method-call sugar は削除済み（#13a）
- [ ] `vibe/` を現行構文へ寄せる（第二段階）
  - grammar 追加後に `String` index/slice や軽量 struct syntax へ移行する
  - `[]` 型推論の改善後に `Array::slice([dummy], 0, 0)` → `[]` を再実施する

## ユーザビリティ改善

### 高優先度（日常的な不便）

- [x] `==` で String/値比較（既に動作していた。examples を `==` スタイルに更新済み）
- [x] Map 操作のビルトイン化: `Map::set(m, key, value)` 追加、`Map[K, V]` ジェネリック化、Hash トレイトバウンド
- [x] メソッド構文の導入（`s.length()` 等。checker/eval で type-directed resolution）

### 中優先度（ボイラープレート削減）

- [ ] String index / slice 構文 `s[i]`, `s[i..j]`, `s[..j]`, `s[i..]`
  - `vibe/x/url`, `vibe/x/toml`, `vibe/x/regexp` で `String::substring(s, i, i + 1)` が多発している
- [ ] raw string / multiline string（`r"..."`, `"""..."""`）
  - `vibe/x/regexp`, `vibe/x/toml` のエスケープ負荷を下げる
- [ ] 軽量 struct リテラル sugar `Type { ... }`
  - `Type::{ ... }` の冗長さで single-constructor enum に逃げている箇所を減らす
- [ ] `String` を `for-in` 対象にする（`for c in s`, `for i, c in s`）
  - scanner 系 (`vibe/x/url`, `vibe/x/toml`, `vibe/x/color`) の index loop を減らす
- [x] 空 Map リテラル `map {}` のサポート — パーサ・eval・codegen 対応済み
- [x] Array スプレッド構文 `[...xs, new_item]`（パーサ・eval・codegen 対応済み、`Array::concat` にデシュガー）
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
