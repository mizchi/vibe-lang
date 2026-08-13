# Coverage strategy

> **Status:** MoonBit host が退役 (#594) したため、下記 1)
> `coverage-moon` と 2) `coverage-deno` は `src/` 依存で **動かない**（driver
> script も削除済み）。3) の vibe ソース span coverage も計測側
> (`vibe compile --coverage`) が MoonBit host 専用で、コンパイラには移植され
> ていない。**現在動くのは下記「0) コンパイラの関数
> カバレッジ」**。1〜3 は歴史的経緯として残す。

## 0) コンパイラの関数 / 分岐カバレッジ（#cov）

コンパイラ自身を **計測ビルド**して、ワークロード実行時にどの compiler
関数が呼ばれたか（関数カバレッジ）と、どの `if`/`match` 分岐が実行されたか
（分岐カバレッジ）を集計する。MoonBit host 不要（committed seed + node runner）。

### CLI: `vibe test --coverage`

ユーザーの **テスト対象**（テストファイルとその import）のカバレッジは
`vibe test --coverage` で計測する。テストファイルを計測ビルドして実行し、
どの関数・分岐がテストで踏まれたかを per-file + 集計で表示する。

```bash
scripts/vibe_test.sh --coverage path/to/foo_test.vibe   # 単一ファイル
scripts/vibe_test.sh --coverage lib/@vibe/prelude       # ディレクトリ配下の *_test.vibe
```

出力例（負数入力を踏まないテストだと `n < 0` アームが未到達 → 3/4）:

```
ok   foo_test.vibe  [cov fn 3/3, branch 3/4]
[vibe-test] 1 passed, 0 failed (1 files)
[vibe-test] coverage: functions 3/3 (100.00%), branches 3/4 (75.00%) over 1 file(s)
```

`vibe run --coverage`（単一プログラムを実行しつつ計測）も同じ仕組み:

```bash
scripts/vibe_run.sh --coverage path/to/prog.vibex [-- args...]
```

プログラムの出力は stdout、`[vibe-cov]` サマリは stderr、JSON は
`_build/vibe_run/<name>.cov.json`。

per-file の JSON は `_build/vibe_test/coverage/<file>.json`
（`{total,hit,missed,rate,hit_fns,missed_fns,branch{...}}`）。仕組みは
`VIBE_FS_COMPILE` 経路が `VIBE_COVERAGE=1` を尊重して計測コンパイル
（`compile_file_fs_mode_coverage`）するだけで、下記の self-compile 計測と同じ
instrumentation を共有する。

### selfhost test suite の集計指標

`pkf run coverage` は全 `*_test.vibe` をそれぞれ別バイナリとして実行する。
各 entry はその import closure を含むため、同じ compiler 関数が entry ごとに
分母へ現れる。したがって report の `entry_weighted.function` と
`entry_weighted.branch` は **entry-weighted** 指標であり、ユニークな source
coverage として解釈してはいけない。これは既存 gate の安定した比較値として残す。

`function_union` は per-entry の `hit_fns` / `missed_fns` を source-qualified
function ID で union した primary 指標である。いずれかの entry で実行された
関数を一度だけ数えるため、suite 全体が到達した compiler 関数の実態を表す。
`branch_union` は branch の同じ指標 (#1556)。branch の**大域 index は
entry ごとの program 固有**なので entry 間で比較してはいけないが、
**owner 関数の中での ordinal** はその関数の本体を lower した順序そのものなので、
`(source-qualified な owner 関数名, ordinal)` は同じ source 上の branch を
どの entry でも同じように名指す。per-entry JSON の
`branch.per_fn[fn].mask` (branch 1つにつき `'1'`/`'0'` 1文字、ordinal 昇順)
がこの ordinal を公開しており、report 側はこれを OR して union を出す。

- **`branch_union.rate` が #1556 の「分岐カバレッジ N%」目標の指標**。
  entry-weighted の branch rate は分母が entry 数で膨らむので目標には使えない
- 同じ source 関数が entry ごとに異なる branch 数へ lower される
  (特殊化・辞書渡し) ことがあるため、union は**見えた最大の shape** に広げる
- **entry ごとに合成される名前 (`_start` / `__test_<名前>` / `__bench_<名前>`)
  だけは entry path で修飾する** (`union_key`)。これらは source 修飾を持たない
  ので、別 entry が同じ綴りの test ブロックを持つと同一名に落ちる (実例:
  `hashmap_test.vibe` と `sortedmap_test.vibe` の `test "empty map"` は branch
  数が 2 と 4 で違う)。名前だけで束ねると分母から小さい方が消え、片方で踏んだ
  branch がもう片方の別の branch を covered にしてしまう。逆に `Array::map` /
  `T::equals` のように source 修飾を持たないが**本当に共通**の名前もあるので、
  修飾してよいのは合成名だけ (test/bench ブロックは import されないので、
  この class に限り「同名 = 別関数」が常に成り立つ)
- mask を持たない (mask 導入前の) coverage JSON が1つでも混ざると
  `branch_union.exact` が `false` になり、値は**下限**として表示される。
  この場合 ratchet は測れなかった数値で落とさないようスキップされる

ratchet: `VIBE_SUITE_MIN_BRANCH_UNION_HIT` (絶対数) と
`VIBE_SUITE_MIN_BRANCH_UNION_RATE` (率)。entry を足すと分母がその import
closure ぶん増える entry-weighted rate と違い、union の rate は
「テストを足せば上がる」ので率のラチェットとして意味を持つ。

### コンパイラ自身を計測

```bash
scripts/coverage_fn.sh                  # 既定: コンパイラの self-compile を計測
scripts/coverage_fn.sh path/to/foo.vibe # foo.vibe をコンパイルする経路を計測 (FS mode)
VIBE_COV_SHOW_MISSED=1 scripts/coverage_fn.sh        # 未実行関数も列挙
VIBE_COV_SHOW_BRANCH_GAPS=1 scripts/coverage_fn.sh   # 未到達分岐が多い関数 top50
```

#### 複数ワークロードのマージ

単一ワークロードは経路が偏る: self-compile は parser/checker/codegen を踏むが
printer（`print_expr`/`print_stmt`）は `normalize` でしか、Perceus RC
（`pc_count`/`pc_emit`/`elaborate_rw`）は `VIBE_RC=1` でしか踏まれない。
`coverage_merge.sh` は **1 つの計測コンパイラ**を複数ワークロードで
走らせ、ヒット bitmap を **union 合成**する（同一バイナリ＝同一 id なので
正確に OR できる）。

```bash
scripts/coverage_merge.sh                 # 既定: compile + normalize + rc
scripts/coverage_merge.sh extra1.vibe ... # 追加で各ファイルを FS-compile
VIBE_COV_SHOW_BRANCH_GAPS=1 scripts/coverage_merge.sh
```

実測（合成効果）: compile 単体 646fn/2436br → **merged 733fn(62.4%) /
2835br(42.5%)**。`print_*` は normalize で、`pc_*`/`elaborate_rw` は rc で
0% から点灯する。`_build/coverage/selfhost-merge/merged.json` に
per-workload 内訳 + union 結果（`per_fn` / `top_gaps`）が出る。

マージは **同一の計測バイナリ**を別ワークロードで回した結果にのみ有効
（関数/分岐 id が一致するため）。別々にコンパイルしたモジュール同士は id が
異なるのでマージ不可。runner 側は `VIBE_COV_RAW=1` のとき report に id 単位の
bitmap（`raw.fn_bitmap` / `raw.branch_bitmap` + 静的な name/owner 表）を足す。

#### コーパス（大量プログラム）でのマージ

`coverage_merge.sh` の固定 3 ワークロードでは分岐 ~56% で頭打ちになる。
`coverage_corpus.sh` は 1 つの計測コンパイラを **多数の .vibe**
（`examples/` `fixtures/` `lib/@vibe/prelude/`）に対して compile / normalize / rc で
走らせ、全 run を union する。

```bash
scripts/coverage_corpus.sh                 # 既定: examples fixtures + 生成エラーコーパス
VIBE_COV_MAX=200 scripts/coverage_corpus.sh
VIBE_COV_SHOW_BRANCH_GAPS=1 scripts/coverage_corpus.sh
```

corpus は base self-compile / RC-stress に加えて以下のワークロードを束ねる:
- **cache-orch**: `compiler_sources_manifest.tsv` を持つコンパイラツリーと
  複数 import の example を、`_build/vibe_selfhost_*` の各キャッシュファイルを
  選択的に無効化しながら繰り返し compile する。これにより
  persistent-cache の read 経路（`parse_persistent_*_cache` /
  `matches_cached_file_spec` / `scan_header_*` / `serialize_type` 等、
  単発 compile では絶対に踏めない分岐）が点灯する（`serialize_type` は
  0→17/19 に上がった）。
- **生成エラーコーパス** (`scripts/coverage_gen_errcorpus.sh` →
  `_build/errcorpus/`): 意図的に ill-typed / mis-parse なプログラムを多数生成。
  「失敗 compile も abort 時に bitmap を dump する」修正（commit 1ea7b6f）と
  併せて、診断系関数（`tk_name` / `type_to_string` / `check_expr` の防御アーム）
  を点灯させる。

実測（examples + fixtures + errcorpus + cache-orch + RC-stress, 626+ files）:
**関数 1020/1174 (86.9%)・分岐 4490/6679 (67.2%)**。`_build/coverage/selfhost-corpus/`
に `acc.json`（running union）/ `merged.json` / `fails.txt`。

注意点（ドッグフーディングで判明）:
- **計測対象は「コンパイル」のみ**。生成された wasm を実行しても、それは別の
  （非計測）バイナリなので計測コンパイラのカバレッジは増えない。
- 失敗ファイルも abort 時に bitmap を dump する（commit 1ea7b6f 以降）。
  **エントリ名はファイルに実在するものを選ぶ**こと（test ファイルは
  sentinel → `_start`）。
- bump モード（既定）は Perceus（`pc_*`/`elaborate_rw`）を踏まないので、
  heap-heavy な小プログラムを `VIBE_RC=1` で別途 compile する RC-stress を含める。

#### 分岐カバレッジの実効上限（2026-06-24, ブラックボックス計測）

`vibe test --coverage` / corpus は **「コンパイラに任意の入力を食わせて
コンパイルさせる」ブラックボックス計測**なので、構造的な上限がある。
広いコーパス + cache-orch + error/feature corpus を総動員しても **分岐 ~67%
で頭打ち**になる（関数は ~87%）。未到達 ~2189 分岐の内訳:

| 区分 | 未到達分岐 | 性質 |
|------|-----------|------|
| 散在する防御アーム（"other", 371 fns） | ~795 | 各関数 1〜2 個の "should not happen" throw / レアパス。関数ごとに専用トリガが要る |
| parser 防御アーム | ~301 | 特定トークンが unexpected になる組合せ（`tk_name` の 87 アームは各トークン種ごとに別プログラムが要る） |
| persistent-cache 状態 | ~272 | manifest header 再読込・fingerprint mismatch 等、多段の cache 状態を厳密に作り込む必要 |
| checker アーム（`check_expr`/`unify`/`types_equal`） | ~239 | 大半が型エラー診断・防御分岐 |
| codegen アーム（`compile_call`/`compile_expr`/`compile_wasi_*`） | ~201 | builtin dispatch・compile mode/flag の分岐 |
| import/module rewrite | ~191 | private 値/型・alias import の multi-file 構成が要る |
| 診断フォーマット（`type_to_string`/`__to_string`/`tk_name`） | ~190 | 各型/トークン形ごとにエラーを起こす専用入力が要る。`__to_string`(24) は通常 compile 経路で呼ばれない |

#### test-execution 計測（2026-06-24, 上記方式 #1 を実装）

`scripts/coverage_testexec.sh` は `lib/@vibe/compiler/*_test.vibe` を
**coverage 付きでコンパイル → 生成 wasm を実行**し、実行された分岐を corpus に
`(関数名, 関数内 local 分岐 index)` キーで union する（別バイナリだが同一ソース
関数なら local 分岐順が一致するのでマージできる）。テストは `type_to_string` /
`unify` / `types_equal` 等の内部関数を assert で直接呼ぶため、ブラックボックス
compile では届かない分岐が点灯する（例: `types_test` 実行で `type_to_string`
21/29、黒箱では ~3/29）。

multi-module ワークロード（`coverage_gen_errcorpus.sh` の `mod_*/`: private
enum/struct/type-alias を export API 経由で使う・alias import・re-export facade・
diamond import）で namespace 経路も点灯（`namespace_private_value_stmts` 2→22 等）。

実測（黒箱 corpus + test-execution）: **分岐 4695/6694 (70.1%)**・関数 87%。
black-box corpus 単体は 68.8%。

#### driver 計測（cyclic blocker を迂回した直接呼び出し）

flat module source（`_cli_adapter_module_source.vibe` = コンパイラ全体を
import 無しで 1 ファイルに inline したもの）は循環 re-export を持たない。ここへ
`scripts/coverage/cov_driver.vibe` を append し、entry `cov_driver_main` で
compile+run すると、コンパイラの型/trait/env 関数を**直接** edge-case 入力で
叩ける（`type_to_string`/`serialize_type` を全 Type variant、`unify`/`types_equal`
を全ペア、trait 付き TypeEnv で `trait_supers`/`type_implements_trait`、
`canonical_builtin_name`/`lookup_array_group_b`/`type_name_prefix` 等）。
黒箱 compile では絶対に踏めない arm が点灯する: `type_to_string` 3→27/29、
`types_equal` 66→83/99、`subst_apply` ~0→21/22、`type_name_prefix` 0→13/13。

```bash
scripts/coverage_driver.sh   # corpus acc.json へ (fn,local_branch) キーで union
```

driver は flat source の全 top-level 関数（export 有無を問わず同一ファイル内で
in-scope）を直接叩ける。型/trait/env に加え以下も edge-case 入力で網羅する:
- **tk_name / is_non_pipe_infix**: 全 Token variant を構築して呼ぶ
  (tk_name 38→86/87、is_non_pipe_infix 2→19/19)。各 token の error 表示 arm は
  パーサが各 token で失敗しないと踏めないが、driver は 1 回で全部踏む。
- **persistent-cache parsers**: `parse_persistent_manifest_header_cache` /
  `source_list_cache` / `source_group_cache` / `split_header_values` を多様な
  TSV 文字列で呼ぶ。FS compile 経路では grouped path が辿らず 0% だが純粋
  String parser なので直接到達 (manifest_header_cache 0→18/26 等)。
- **canonical_builtin_name**: 全 Fs/Env/Profiler builtin 名で呼ぶ (2→20/20)。
- **Expr 系**: 全 Expr variant を構築し `expr_projects_or_matches` (18→46/60)・
  `desugar_loop_body` (12→23/26)・`rewrite_private_type_ctor_expr` (16→34/35)。
- 一方 `compile_*` / `check_expr` / `fold_expr` 等は 728-file corpus が compile
  時に必ず通すので driver からは +0〜+4（冗長）。

実測（黒箱 corpus + driver + test-execution の union）:
**分岐 4955/6694 (74.02%)**・関数 1026/1176 (87.24%)。
内訳: corpus 68.76% → +driver 74.0% (+255) → +test-exec 74.02%。

#### 80% 達成（no-DCE merged source + direct-call drivers）

> **#1633 migration status: done for `coverage_drivers.sh`.** The historical raw
> concatenation described below has been deleted; all 39 registered drivers use
> compiler-owned exact-path value exposure. Their imports name one `.vibe` file
> in the collected compiler closure, the production export/private namespacing
> plan determines the final target name, and the existing shadow-aware import
> rewriter updates driver references before entry-based DCE. Missing, duplicate,
> out-of-closure, type/constructor, mutable-global, extern, method, and collision
> requests fail with a diagnostic. The internal mode
> (`VIBE_EMIT_COVERAGE_DRIVER_SOURCE=1` + `VIBE_COVERAGE_DRIVER_PATH`) is invoked
> only by `coverage_drivers.sh`; it does not widen normal import visibility or
> change `VIBE_EMIT_MERGED_SOURCE` output.
>
> なぜ raw concat を残せなかったか: あの walk は**相対 import しか辿らない**ので
> `.vpkg` パッケージ import (#1269/#897) 以降は数ホップで止まり、~5MB のはずの
> base が 67KB しか出ていなかった (= 全 driver が `unknown name` で死ぬ)。
> 仮に walk を直しても、300 ファイルを無資格に連結した base は同名の private
> ヘルパを first-match roulette で解決するので、どの関数のカバレッジを測ったのか
> が決まらない。exposure が production の rename plan を経由するのはそのため。

**分岐 5711/6694 (85.32%)**・関数 1037/1176 (88.18%) に到達（85% = 5690 に対し +21 のマージン、下限ガード 80% に対し +355）。
74% で頭打ちだった主因（コンパイラ自身の unit test 120/148 が builtins⇄checker
の循環 re-export で FS-compile 不能）を、**循環 re-export を直さずに**回避した。

鍵は **DCE を跨いで関数へ到達する**こと。flat module source
(`_cli_adapter_module_source.vibe`) は `build_module_source_from_source` が
entry `cli_main` から DCE するため、テストだけが使う ~530 関数が欠落していた。

当時の答えは **no-DCE merged source** (`_build/coverage/merged_nodce.vibe`)
＝ manifest 全ファイルを import 除去で連結した base だった（全 top-level 関数が
in-scope、import 文が無いので循環 re-export blocker も踏まない）。**この lane は
#1633 で削除済み**（上の blockquote 参照）。今は driver 側が exact-path import で
必要な関数を名指しし、その driver entry を根に DCE する — 目的（テストしか呼ばない
関数へ到達する）は同じで、どの関数を測っているかが名前で決まる点だけが違う。

driver を base へ足したものを coverage 付き compile+run し、実行分岐を
corpus acc.json に (fn_name, local_branch_index) キーで union する。分母（seed
コンパイラの分岐）は不変なので、seed に存在する関数の未踏 arm だけが点灯する。

レバー別の寄与（76.25% から）:
- **no-DCE unit-tests** (`coverage_unittests.sh` + `VIBE_COV_FLAT`):
  flat の代わりに no-DCE merged を base にし、`*_test.vibe` を 28→**68 本**実行
  (+82)。残 80 本は seed に無い standalone module（`desugar`/`monoify`/`cst_lower`/
  `analyze_purity` 等）を import するため分母外で無意味。
- **direct-call drivers** (`coverage_drivers.sh`): seed の under-tested
  関数を crafted 入力で直接叩く。**黒箱 compile では構造的に踏めない category**:
  - `cov_async.vibe`: inlined async/stream builtin (`Stream::map`/`await`/…)
    — examples に async プログラムが無い (+32)。`Task::*` を叩いていた分は
    #1227 の eager prototype 撤去で外した。
  - `cov_lookup.vibe`: builtin name→Type dispatch chain
    (`lookup_array`/`lookup_io_b`) を全 builtin 名で呼ぶ (+25)。
  - `cov_cachetext.vibe`: persistent-cache フォーマット parser の version/arity/
    unknown-tag/CR arm を crafted TSV で (+16)。
  - `cov_units.vibe` / `cov_units2.vibe`: 小 helper を直接呼ぶ
    (`strip_trailing_cr`/`emit_assignop_op`/`lookup_iter_intrinsic`/
    `matches_cached_file_spec` の exists/stat/fingerprint 全 arm 等) (+26)。
  - `cov_traitenv.vibe`: `type_implements_check_super` の TypeEnv 全 variant
    (`EnvTraitImpl` の eq+sub/eq+nosub/neq、`EnvFlat`/`EnvCached`/…) を構築 (+11)。
  - `cov_link.vibe`: `compile_wasi_module_linked_impl` の linked_imports>0 /
    library_mode arm（shipped compiler では DCE 済み caller 経由でしか到達不能）
    を synthetic linked import で直接 (+11)。
  - `cov_builtins.vibe` / `cov_parse.vibe`: Array/String/Map/Bytes builtin、parser
    arm（多くは self-compile で既出、残差を補う）。
  - `cov_helpers.vibe`: **unique-named** pure helper を全入力 partition で叩く
    (`comp_valtype_to_core` の全 valtype、`parse_int_unwrap` の符号/空/非数字、
    `lookup_io_a`/`lookup_io_c` の dispatch chain、`double_to_string_compiler` の
    繰り上げ/frac==0、`entry_declares_async_int`) (+28)。注: `(fn,local)` merge は
    関数名で union するため、merged source 内に**重複定義**を持つ helper
    (`strip_trailing_cr`/`parse_struct_fields_rest` 等) は local-index がずれて
    点灯しない — driver は unique-named 関数に限定する。
  - `cov_syntax.vibe`: parser を corpus が踏まない arm へ — slice 記法
    (`a[:]`/`a[1:]`/`a[:2]`)、block-local `let rec`/`let mut`/enum/struct
    (`parse_impl_block`)、if/else-if・is-pattern・match expression mode
    (`parse_impl_dispatch`)。`load_and_parse` で parse のみ走らせ error は握り潰す。
  - `cov_exprwalk.vibe`: unique な再帰 Expr/Pat walker を全 variant 構築で直接叩く
    — `is_mut_captured_in`(`||` 短絡の else 側・`let n==name` shadowing arm)、
    `rewrite_import_alias_expr`、`wrap_placeholder_arg`、`pat_binds_name`(全 Pat
    variant)。Expr/Pat コンストラクタを手で組むため compile 不要で全 arm を踏む
    (`pat_binds_name`/`wrap_placeholder_arg` は 0 dark まで到達) (+25)。注:
    whole-program compile を増やしても corpus が飽和済みで +0〜+1（実測で確認）—
    伸びるのは「特定 helper/walker を直接呼ぶ」driver に限る。
  - `cov_fscache.vibe`: `load_source_if_cached_file_spec_matches`（unique な 8-arm
    Fs validator: missing / stat-match / stat-miss+fp-match / +fp-miss / +fp-empty /
    no-stat+fp-{match,miss,empty}）を、実 fixture `_build/covfs/f.vibe` の本物の
    `Fs::stat_token` / `compact_string_fingerprint` 値と、わざと外した値で全 arm 踏破
    （0 dark 到達）(+11)。注: その Bool twin `matches_cached_file_spec` は merged
    source に重複定義があり 10 dark は dead copy（駆動不能）。
- **manifest-header cache** (`coverage_manifestcache.sh`): 非 special な
  manifest project を cold/warm/部分 invalidation で FS-compile し、
  `matches_cached_file_spec`/`try_collect_manifest_source_groups_fs`/
  `collect_needed_paths_from_manifest_headers` を点灯 (+32)。コンパイラ自身の
  manifest は cold で trap するため cache が書かれず、この cluster が dark だった。
- **multi-module merge** (`coverage_multimodule.sh`): 非 entry module が
  private let/enum/struct/type-alias を持ち、entry が同名 export を別 alias で
  import する（衝突）project を FS-compile → `namespace_private_value_stmts`/
  `append_import_alias_collision_defs_from_sources` 系を点灯 (+16)。
- **feature programs** (`coverage_features.sh`): trait/効果/mut capture/
  pattern 等の breadth (+14)。

再現:
```bash
scripts/coverage_corpus.sh        # base acc.json + compiler_cov.wasm
scripts/coverage_unittests.sh     # base は flat module source (#1633 で no-DCE merged base は無くなった)
scripts/coverage_drivers.sh       # async/lookup/cachetext/units/traitenv/link/helpers/…
scripts/coverage_manifestcache.sh
scripts/coverage_multimodule.sh
scripts/coverage_features.sh
```

`coverage_corpus.sh` は実行前に生成 compiler source と必須入力の存在・鮮度を
検証するだけで、自動再生成はしない。不足・stale の場合は
`bash scripts/ensure_generated.sh` を実行するよう診断する。repository 内の
host path を Python `relpath` + containment check で作るため、GNU
`realpath --relative-to` を持たない BSD/macOS でも同じ入力を使う。driver の
checkout-local merge tool は corpus が生成した現在の `compiler_cov.wasm` で
compile する（committed seed は compiler が emit した通常の merged source を
compile する役割だけ）。merge は command status と `base now total` schema を
検査し、`total > 0`、分母不変、hit 非減少、書込み後 stat 一致を満たさなければ
coverage run 全体を失敗させる。

#1633 の production exact-path exposure へは、`coverage_drivers.sh` に登録された
**39 本すべてが移行済み**。legacy raw base (`_build/coverage/merged_nodce.vibe`)
とそれを作っていた Python walk は削除した。`cov_driver.vibe` は現在の
`coverage_drivers.sh` に登録されない historical monolith（`coverage_driver.sh`
単数形からのみ参照され、そちらは flat module source への raw concat のまま）なので、
移行対象へ戻すか退役するかを別途決める。ここで件数へ含めたり暗黙に実行済みとは
扱わない。

移行で分かったこと: 全 driver が壊れたまま放置されていた間に、driver が呼ぶ
コンパイラ側 API が動いていた。AST ノードのアリティ (`EIdent`/`ECall`/`EDot` の
byte offset スロット、`SEnum` の derives、`SStruct` の #829 スロット)、
parser 内部の `starts: Array[Int]` (#1567 located diagnostics) と `parse_recur`
コールバック、`check_pattern` の errors シンク、`flatten_module_body` が
alias 配列ではなく rewriter を取るようになった点など。消えた target
(`lookup_array_group_b` → `lookup_array`、`lookup_io_c` → `lookup_io_b` へ吸収、
`lookup_assert` → checker.vibe のインライン名前判定、`parse_int_unwrap` →
`parse_int_or`) は現行の後継へ差し替えるか、後継が無いものは理由付きで削った。

#### 構造的に到達不能な残差（~19 dark）

80% 到達後も残るのは大半が構造的:
- `__to_string`(18): runtime builtin が intercept する host-shadowed 関数（vibe
  本体は dead）。
- `compile_wasi_module_linked_impl` 残 arm: 実 linked dep の resolved_type_stmts
  を要する path（synthetic linked import では届かない）。
- `check_expr`/`compile_expr`/`compile_call` の深い防御 arm: 728-file corpus が
  既に飽和しており、ordinary/error プログラムでは +0（battery/error 実測で確認）。

KPI: **分岐 80% を下限ガード**、関数（~88%）と併用。driver suite は
seed に新関数が増えても (fn,local) merge でそのままスケールする。

仕組み:
- `VIBE_COVERAGE=1` でコンパイルすると、codegen が
  - 各 user 関数の入口に「ヒットフラグを 1 立てる」store を挿入し（heap 直下の
    予約領域に 1 byte/関数の bitmap）、`vibe_cov` custom section に `cov_base` /
    `cov_count` / 関数名を埋め込む。
  - 各 `if` の then/else と各 `match` アーム（catch-all 含む。条件アームが 1 つ
    以上あるときのみ）の先頭に、同じく 1 byte/分岐の store を挿入する。分岐 id は
    codegen 走査順に採番（`CovState` の可変セル経由）、固定上限 65536。
    `vibe_cov_branch` custom section に `base` / `count` / 各分岐の所属関数 index
    を埋め込む。
- 計測コンパイラを実行 → 両 bitmap が埋まる → runner が `VIBE_COV_OUT` 指定時に
  memory を読み、関数名・所属関数と突き合わせて report.json を出力。分岐は所属
  関数ごとに集計され、未到達分岐の多い関数が `branch.top_gaps` に並ぶ。
- `VIBE_COVERAGE` を立てない通常ビルドは **byte 単位で従来と同一**（gate の
  stage2==stage3 fixpoint で担保）。計測は bootstrap に影響しない。
- 分岐は `if`/`match` のみ（`&&`/`||` の短絡は未計測）。真の **行単位**カバレッジは
  AST がソース位置を持たず、recursive-descent parser に byte 位置を配線する大改修が
  必要なため未実装（別タスク）。

生成物 (`_build/coverage/selfhost-fn/`):
- `compiler_cov.wasm` — 計測コンパイラ
- `report.json` — `{total, hit, missed, rate, hit_fns[], missed_fns[],
  branch: {total, hit, missed, rate, per_fn{}, top_gaps[]}}`。
  `per_fn[fn]` は `{total, hit, mask}` で、`mask` は branch 1つにつき
  `'1'`/`'0'` 1文字 (owner 関数内 ordinal の昇順) — 別 program 間で branch を
  同定できる唯一の鍵 (#1556)

環境変数:
- `VIBE_COV_SEED` (計測ビルドに使う seed; 既定は committed seed)
- `VIBE_COV_DIR` (出力先)
- `VIBE_COV_SHOW_MISSED` / `VIBE_COV_SHOW_BRANCH_GAPS` (サマリ詳細)
- `VIBE_COV_SHOW_MISSED` (`1` で未実行関数を表示)

低レベル API:
- `VIBE_COVERAGE=1 cli_main <src> <out.wasm> <entry>` — 計測 wasm を生成
- `VIBE_COV_OUT=<report.json>` を runner に渡すと、実行後に bitmap を dump

粒度は関数レベル（line/branch ではない）。AST がソース位置を保持しないため
line/branch は span 配線が前提で別途実装が必要。関数レベルでも「未到達・
未テスト経路の検出」には十分有効（例: dead な `__to_string` inline path のような
穴は missed_fns に現れる）。

---

以下は MoonBit host 時代の coverage（歴史的経緯、現在は動かない）。

このプロジェクトでは coverage を 3 つに分けて測る。

1. MoonBit 本体コードの行カバレッジ
2. WASM 成果物をホストから呼ぶ統合導線のカバレッジ
3. vibe ソース span ベースの WASM 実行カバレッジ（line/branch）

## 1) MoonBit 本体カバレッジ

`moon test --enable-coverage` + `moon coverage report` を使う。

```bash
just coverage-moon
```

生成物:
- `_build/coverage/moon/summary.txt`
- `_build/coverage/moon/moonbit-cobertura.xml`
- `_build/coverage/moon/html/index.html`

環境変数:
- `VIBE_MOON_COVERAGE_TARGET` (`native` / `wasm` / `wasm-gc` / `js`)
- `VIBE_MOON_COVERAGE_PACKAGE` (例: `parser`)
- `VIBE_MOON_COVERAGE_MIN_LINE` (行カバレッジ閾値, 整数%)
- `VIBE_MOON_COVERAGE_DIR` (出力先ディレクトリ)

例:

```bash
VIBE_MOON_COVERAGE_TARGET=wasm-gc \
VIBE_MOON_COVERAGE_PACKAGE=parser \
VIBE_MOON_COVERAGE_MIN_LINE=70 \
just coverage-moon
```

## 2) WASM 統合カバレッジ

`tests/integration-deno/` は `src/lib` の wasm-gc 成果物を
`WebAssembly.instantiate` で直接テストする。ここは Deno coverage で測る。

```bash
just coverage-deno
```

生成物:
- `_build/coverage/deno/summary.txt`
- `_build/coverage/deno/lcov.info`
- `_build/coverage/deno/html/index.html`

環境変数:
- `VIBE_DENO_COVERAGE_FILTER` (テスト絞り込み)
- `VIBE_DENO_COVERAGE_MIN_LINE` (行カバレッジ閾値, 整数%)
- `VIBE_DENO_COVERAGE_DIR` (出力先ディレクトリ)

例:

```bash
VIBE_DENO_COVERAGE_FILTER='vibe wasm api' \
VIBE_DENO_COVERAGE_MIN_LINE=60 \
just coverage-deno
```

## WASM での考え方

WASM で「何を coverage と見なすか」を分離するのが実務的:

- コンパイラ/型検査などの本体ロジック: MoonBit coverage
- wasm export の API 契約とホスト接続: Deno coverage

この分離により、`wasm-gc` 実行経路の回帰と API 回帰を同時に監視できる。

## 3) vibe ソース span ベース WASM カバレッジ

`vibe compile --coverage` で生成する `.cov.json` と wasm カウンタを使って、
vibe ソース基準の line/branch ヒットを集計する。

```bash
just coverage-wasm-source fixtures/pattern_coverage_test.vibe
```

生成物:
- `_build/coverage/wasm-source/<entry>.summary.txt`
- `_build/coverage/wasm-source/<entry>.report.json`
- `_build/coverage/wasm-source/<entry>.wasm.cov.json`

環境変数:
- `VIBE_WASM_SOURCE_COVERAGE_MODE` (`wasm` / `wasm-js-string`)
- `VIBE_WASM_SOURCE_COVERAGE_NO_DCE` (`0` / `1`)
- `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS` (`0` / `1`)
- `VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP` (`0` / `1`)
- `VIBE_WASM_SOURCE_COVERAGE_DIR` (出力先ディレクトリ)

実装上の制約:
- `compile --coverage` は test 専用で、`VIBE_TEST_COVERAGE=1` が必要
- 通常開発では `coverage-wasm-source` ツール経由でのみ生成する
- `VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1` で `test {}` を実行可能
  (`compile --coverage --coverage-run-tests`)

### vibe/prelude 一括計測

`vibe/prelude/**/*_test.vibe` をまとめて回すときは:

```bash
just coverage-wasm-std
```

生成物:
- `_build/coverage/wasm-std/summary.txt`
- `_build/coverage/wasm-std/report.json`
- `_build/coverage/wasm-std/report.md`
- `_build/coverage/wasm-std/reports.txt`
- `_build/coverage/wasm-std/attempts.tsv`
- `_build/coverage/wasm-std/failures.txt`

環境変数:
- `VIBE_WASM_STD_COVERAGE_MODES` (カンマ or 空白区切り; 例: `wasm,wasm-js-string`)
- `VIBE_WASM_STD_COVERAGE_MODE` (単一モード指定; `MODES` 未指定時のみ利用)
- `VIBE_WASM_STD_COVERAGE_NO_DCE` (`0` / `1`)
- `VIBE_WASM_STD_COVERAGE_STRICT` (`0` / `1`)
- `VIBE_WASM_STD_COVERAGE_ALLOW_TRAP` (`0` / `1`)
- `VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE` (`0..100`, 任意)
- `VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE` (`0..100`, 任意)
- `VIBE_WASM_STD_COVERAGE_FILTER` (`rg` パターン)
- `VIBE_WASM_STD_COVERAGE_EXCLUDE` (`rg` パターン)
- `VIBE_WASM_STD_COVERAGE_MATRIX` (backend capability matrix JSON)
- `VIBE_WASM_STD_COVERAGE_DIR` (出力先ディレクトリ)

デフォルトでは `wasm -> wasm-js-string` の順でフォールバック実行する。
各試行の結果は `attempts.tsv` と `cases/*.log` に残り、`report.json` には以下が入る。

- `failed_case_details[]`: ケースごとの失敗理由 (`compile_unsupported` / `runtime_trap` など) と mode 別試行履歴
- `failure_reason_counts`: 失敗理由の集計
- `execution.trap_case_count`: 実行時 trap したケース数（計測自体は保持）
- `spec.expected_failure_count` / `spec.unexpected_failure_count`:
  backend capability matrix に対する仕様内/仕様外の失敗件数
- `spec.mismatch_case_count`:
  計測成功ケースの実行 backend が `expected_backend` と不一致だった件数

`vibe/prelude/backend_capabilities.json` をデフォルト matrix として読み込み、
失敗ケースごとに `expected_backend` (`wasm` / `wasm-js-string` / `either`)
を参照して `spec_status` を付与する。
`VIBE_WASM_STD_COVERAGE_STRICT=1` では `unexpected_failure` または
`mismatch_case_count > 0` の場合に失敗する。

coverage の有効性判断は、全体率だけでなく `cases(total/measured/failed)` と `failure_reason_counts` を併せて行う。
必要なら KPI gate を有効化し、閾値未達でコマンドを失敗させる。

line 率は `line point` の重複ではなく `raw.lines` の unique line 数を使って集計する。
`point` は細粒度カウンタ、`line` は運用 KPI として使い分ける。
さらに `raw.lines` では source-map ノイズ（import 列挙行、構文ブロック終端の `}` 行）を
`excluded=true` として line KPI から除外する。

```bash
VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE=50 \
VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE=55 \
just coverage-wasm-std
```

## Coverage の有用性判定（2026-02-11）

実測（このリポジトリ現状）:
- MoonBit coverage (`just coverage-moon`): `18718/29541` (`63.36%`)
- Deno integration coverage (`just coverage-deno`): `All files line 69.9%`
- vibe/prelude wasm coverage (`just coverage-wasm-std`): `626/626` (`100.00%`)

運用判断:
- `coverage-moon` はコンパイラ/型検査本体の回帰検知に有効（本命KPI）。
- `coverage-deno` は wasm export 契約と JS バインディング回帰の検知に有効。
- `coverage-wasm-std` は std テストシナリオの抜け検知に有効（backend matrix + strict 併用）。
- 逆に、coverage 単体では意味論の正しさは保証しないため、
  golden / integration / fixture テストとセットで見る。

## 一括実行

```bash
pkf run coverage                            # selfhost suite coverage 集計
pkf run coverage-suite-branch-gate # branch coverage gate
pkf run coverage-suite-next-branches  # 未到達分岐の提案
```

> 旧 `coverage-moon` / `coverage-deno` / `coverage-wasm-source` / `coverage-wasm-std`
> は MoonBit host 退役 (#594) で撤去済み。現在動くのは上記 selfhost-suite 系のみ
> (セクション 0 参照)。
