# Coverage strategy (MoonBit + WASM)

このプロジェクトでは coverage を 3 つに分けて測る。

1. MoonBit 本体コードの行カバレッジ
2. WASM 成果物をホストから呼ぶ統合導線のカバレッジ
3. xsh ソース span ベースの WASM 実行カバレッジ（line/branch）

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
- `XSH_MOON_COVERAGE_TARGET` (`native` / `wasm` / `wasm-gc` / `js`)
- `XSH_MOON_COVERAGE_PACKAGE` (例: `parser`)
- `XSH_MOON_COVERAGE_MIN_LINE` (行カバレッジ閾値, 整数%)
- `XSH_MOON_COVERAGE_DIR` (出力先ディレクトリ)

例:

```bash
XSH_MOON_COVERAGE_TARGET=wasm-gc \
XSH_MOON_COVERAGE_PACKAGE=parser \
XSH_MOON_COVERAGE_MIN_LINE=70 \
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
- `XSH_DENO_COVERAGE_FILTER` (テスト絞り込み)
- `XSH_DENO_COVERAGE_MIN_LINE` (行カバレッジ閾値, 整数%)
- `XSH_DENO_COVERAGE_DIR` (出力先ディレクトリ)

例:

```bash
XSH_DENO_COVERAGE_FILTER='xsh wasm api' \
XSH_DENO_COVERAGE_MIN_LINE=60 \
just coverage-deno
```

## WASM での考え方

WASM で「何を coverage と見なすか」を分離するのが実務的:

- コンパイラ/型検査などの本体ロジック: MoonBit coverage
- wasm export の API 契約とホスト接続: Deno coverage

この分離により、`wasm-gc` 実行経路の回帰と API 回帰を同時に監視できる。

## 3) xsh ソース span ベース WASM カバレッジ

`xsh compile --coverage` で生成する `.cov.json` と wasm カウンタを使って、
xsh ソース基準の line/branch ヒットを集計する。

```bash
just coverage-wasm-source examples/pattern_coverage.vibe
```

生成物:
- `_build/coverage/wasm-source/<entry>.summary.txt`
- `_build/coverage/wasm-source/<entry>.report.json`
- `_build/coverage/wasm-source/<entry>.wasm.cov.json`

環境変数:
- `XSH_WASM_SOURCE_COVERAGE_MODE` (`wasm` / `wasm-js-string`)
- `XSH_WASM_SOURCE_COVERAGE_NO_DCE` (`0` / `1`)
- `XSH_WASM_SOURCE_COVERAGE_RUN_TESTS` (`0` / `1`)
- `XSH_WASM_SOURCE_COVERAGE_ALLOW_TRAP` (`0` / `1`)
- `XSH_WASM_SOURCE_COVERAGE_DIR` (出力先ディレクトリ)

実装上の制約:
- `compile --coverage` は test 専用で、`XSH_TEST_COVERAGE=1` が必要
- 通常開発では `coverage-wasm-source` ツール経由でのみ生成する
- `XSH_WASM_SOURCE_COVERAGE_RUN_TESTS=1` で `test {}` を実行可能
  (`compile --coverage --coverage-run-tests`)

### vibe/std 一括計測

`vibe/std/**/*_test.vibe` をまとめて回すときは:

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
- `XSH_WASM_STD_COVERAGE_MODES` (カンマ or 空白区切り; 例: `wasm,wasm-js-string`)
- `XSH_WASM_STD_COVERAGE_MODE` (単一モード指定; `MODES` 未指定時のみ利用)
- `XSH_WASM_STD_COVERAGE_NO_DCE` (`0` / `1`)
- `XSH_WASM_STD_COVERAGE_STRICT` (`0` / `1`)
- `XSH_WASM_STD_COVERAGE_ALLOW_TRAP` (`0` / `1`)
- `XSH_WASM_STD_COVERAGE_MIN_MEASURED_RATE` (`0..100`, 任意)
- `XSH_WASM_STD_COVERAGE_MIN_LINE_RATE` (`0..100`, 任意)
- `XSH_WASM_STD_COVERAGE_FILTER` (`rg` パターン)
- `XSH_WASM_STD_COVERAGE_EXCLUDE` (`rg` パターン)
- `XSH_WASM_STD_COVERAGE_MATRIX` (backend capability matrix JSON)
- `XSH_WASM_STD_COVERAGE_DIR` (出力先ディレクトリ)

デフォルトでは `wasm -> wasm-js-string` の順でフォールバック実行する。
各試行の結果は `attempts.tsv` と `cases/*.log` に残り、`report.json` には以下が入る。

- `failed_case_details[]`: ケースごとの失敗理由 (`compile_unsupported` / `runtime_trap` など) と mode 別試行履歴
- `failure_reason_counts`: 失敗理由の集計
- `execution.trap_case_count`: 実行時 trap したケース数（計測自体は保持）
- `spec.expected_failure_count` / `spec.unexpected_failure_count`:
  backend capability matrix に対する仕様内/仕様外の失敗件数
- `spec.mismatch_case_count`:
  計測成功ケースの実行 backend が `expected_backend` と不一致だった件数

`vibe/std/backend_capabilities.json` をデフォルト matrix として読み込み、
失敗ケースごとに `expected_backend` (`wasm` / `wasm-js-string` / `either`)
を参照して `spec_status` を付与する。
`XSH_WASM_STD_COVERAGE_STRICT=1` では `unexpected_failure` または
`mismatch_case_count > 0` の場合に失敗する。

coverage の有効性判断は、全体率だけでなく `cases(total/measured/failed)` と `failure_reason_counts` を併せて行う。
必要なら KPI gate を有効化し、閾値未達でコマンドを失敗させる。

line 率は `line point` の重複ではなく `raw.lines` の unique line 数を使って集計する。
`point` は細粒度カウンタ、`line` は運用 KPI として使い分ける。
さらに `raw.lines` では source-map ノイズ（import 列挙行、構文ブロック終端の `}` 行）を
`excluded=true` として line KPI から除外する。

```bash
XSH_WASM_STD_COVERAGE_MIN_MEASURED_RATE=50 \
XSH_WASM_STD_COVERAGE_MIN_LINE_RATE=55 \
just coverage-wasm-std
```

## Coverage の有用性判定（2026-02-11）

実測（このリポジトリ現状）:
- MoonBit coverage (`just coverage-moon`): `18718/29541` (`63.36%`)
- Deno integration coverage (`just coverage-deno`): `All files line 69.9%`
- vibe/std wasm coverage (`just coverage-wasm-std`): `626/626` (`100.00%`)

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
