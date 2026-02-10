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
just coverage-wasm-source examples/pattern_coverage.xsh
```

生成物:
- `_build/coverage/wasm-source/<entry>.summary.txt`
- `_build/coverage/wasm-source/<entry>.report.json`
- `_build/coverage/wasm-source/<entry>.wasm.cov.json`

環境変数:
- `XSH_WASM_SOURCE_COVERAGE_MODE` (`wasm` / `wasm-js-string`)
- `XSH_WASM_SOURCE_COVERAGE_NO_DCE` (`0` / `1`)
- `XSH_WASM_SOURCE_COVERAGE_RUN_TESTS` (`0` / `1`)
- `XSH_WASM_SOURCE_COVERAGE_DIR` (出力先ディレクトリ)

実装上の制約:
- `compile --coverage` は test 専用で、`XSH_TEST_COVERAGE=1` が必要
- 通常開発では `coverage-wasm-source` ツール経由でのみ生成する
- `XSH_WASM_SOURCE_COVERAGE_RUN_TESTS=1` で `test {}` を実行可能
  (`compile --coverage --coverage-run-tests`)

### xsh/std 一括計測

`xsh/std/**/*_test.xsh` をまとめて回すときは:

```bash
just coverage-wasm-std
```

生成物:
- `_build/coverage/wasm-std/summary.txt`
- `_build/coverage/wasm-std/report.json`
- `_build/coverage/wasm-std/reports.txt`
- `_build/coverage/wasm-std/failures.txt`

環境変数:
- `XSH_WASM_STD_COVERAGE_MODE` (`wasm` / `wasm-js-string`)
- `XSH_WASM_STD_COVERAGE_NO_DCE` (`0` / `1`)
- `XSH_WASM_STD_COVERAGE_STRICT` (`0` / `1`)
- `XSH_WASM_STD_COVERAGE_FILTER` (`rg` パターン)
- `XSH_WASM_STD_COVERAGE_EXCLUDE` (`rg` パターン)
- `XSH_WASM_STD_COVERAGE_DIR` (出力先ディレクトリ)

現状は backend 未対応機能を含むケースがあり、`failures.txt` に残る。
coverage の有効性判断は `cases(total/success)` と失敗ケース内訳を併せて行う。

## 一括実行

```bash
just coverage
```

これは `coverage-moon` と `coverage-deno` を順に実行する。
`coverage-wasm-source` は個別シナリオ計測用として別コマンドで実行する。
