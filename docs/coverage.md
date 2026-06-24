# Coverage strategy (MoonBit + WASM)

> **Status (selfhost-only):** MoonBit host が退役 (#594) したため、下記 1)
> `coverage-moon` と 2) `coverage-deno` は `src/` 依存で **動かない**（driver
> script も削除済み）。3) の vibe ソース span coverage も計測側
> (`vibe compile --coverage`) が MoonBit host 専用で、selfhost には移植され
> ていない。**現在 selfhost で動くのは下記「0) selfhost コンパイラの関数
> カバレッジ」**。1〜3 は歴史的経緯として残す。

## 0) selfhost コンパイラの関数 / 分岐カバレッジ（#cov, selfhost-only で動く）

コンパイラ自身を **計測ビルド**して、ワークロード実行時にどの compiler
関数が呼ばれたか（関数カバレッジ）と、どの `if`/`match` 分岐が実行されたか
（分岐カバレッジ）を集計する。MoonBit host 不要（committed seed + node runner）。

### CLI: `vibe test --coverage`

ユーザーの **テスト対象**（テストファイルとその import）のカバレッジは
`vibe test --coverage` で計測する。テストファイルを計測ビルドして実行し、
どの関数・分岐がテストで踏まれたかを per-file + 集計で表示する。

```bash
scripts/vibe_test.sh --coverage path/to/foo_test.vibe   # 単一ファイル
scripts/vibe_test.sh --coverage vibe/prelude            # ディレクトリ配下の *_test.vibe
```

出力例（負数入力を踏まないテストだと `n < 0` アームが未到達 → 3/4）:

```
ok   foo_test.vibe  [cov fn 3/3, branch 3/4]
[vibe-test] 1 passed, 0 failed (1 files)
[vibe-test] coverage: functions 3/3 (100.00%), branches 3/4 (75.00%) over 1 file(s)
```

`vibe run --coverage`（単一プログラムを実行しつつ計測）も同じ仕組み:

```bash
scripts/vibe_run.sh --coverage path/to/prog.vibe [entry]
```

プログラムの出力は stdout、`[vibe-cov]` サマリは stderr、JSON は
`_build/vibe_run/<name>.cov.json`。

per-file の JSON は `_build/vibe_test/coverage/<file>.json`
（`{total,hit,missed,rate,hit_fns,missed_fns,branch{...}}`）。仕組みは
`VIBE_FS_COMPILE` 経路が `VIBE_COVERAGE=1` を尊重して計測コンパイル
（`compile_file_fs_mode_coverage`）するだけで、下記の self-compile 計測と同じ
instrumentation を共有する。

### コンパイラ自身を計測

```bash
scripts/coverage_selfhost_fn.sh                  # 既定: コンパイラの self-compile を計測
scripts/coverage_selfhost_fn.sh path/to/foo.vibe # foo.vibe をコンパイルする経路を計測 (FS mode)
VIBE_COV_SHOW_MISSED=1 scripts/coverage_selfhost_fn.sh        # 未実行関数も列挙
VIBE_COV_SHOW_BRANCH_GAPS=1 scripts/coverage_selfhost_fn.sh   # 未到達分岐が多い関数 top50
```

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
  branch: {total, hit, missed, rate, per_fn{}, top_gaps[]}}`

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
just coverage-wasm-source examples/pattern_coverage.vibe
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
just coverage
```

これは `coverage-moon` と `coverage-deno` を順に実行する。
`coverage-wasm-source` は個別シナリオ計測用として別コマンドで実行する。
