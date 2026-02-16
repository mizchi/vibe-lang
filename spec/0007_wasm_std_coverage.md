# vibe/std Wasm-Source Coverage

Status: accepted (2026-02-11)
Source: TODO.md "vibe/std wasm-source coverage 実用化" 各 [done 2026-02-10/11] 項目

## 概要

`coverage-wasm-std` を multi-mode フォールバック (`wasm -> wasm-js-string`) に対応させ、backend capability matrix による期待値管理と coverage KPI gate を導入した。最終的に全 13 ケースが measured/ok、line coverage 100% を達成。

## 決定事項

1. **Multi-mode フォールバック**: `wasm -> wasm-js-string` の順で試行し、`_build/coverage/wasm-std/attempts.tsv` と `cases/*.log` を出力
2. **レポート拡張**: `report.md` / `report.json` に `failed_case_details[]`, `failure_reason_counts`, `execution.trap_case_count` を追加
3. **Backend capability matrix**: `vibe/std/backend_capabilities.json` で各テストファイルの expected backend (`wasm` / `wasm-js-string` / `either`) を管理。集計時に `spec_status` (`expected_failure` / `unexpected_failure`) を判定
4. **Coverage KPI gate**: `VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE` / `VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE` で下限を指定し、未達時に `coverage-wasm-std` を失敗させる
5. **Codegen 修正**: `abs` / `to_double` / `go` 系の local function alias、method-style 呼び出し、同名ローカル再帰関数のシグネチャ衝突、captured function param 呼び出しを解消
6. **Runtime trap 修正**: tagged-int 範囲の不整合（`int/double` 飽和境界）を修正し、実行 trap を 0 件化

## 背景・理由

vibe/std の wasm バックエンド互換性を定量的に管理する基盤が不足していた。multi-mode フォールバックにより各テストケースが実行可能な最適バックエンドで試行され、capability matrix により期待値とのずれを検出できるようになった。KPI gate により CI で coverage 品質の退行を防止する。

## 実装

- `scripts/coverage_wasm_std.sh` - multi-mode フォールバック実行スクリプト
- `scripts/coverage_wasm_std.mjs` - 集計・レポート生成ロジック
- `scripts/coverage_wasm_std.test.mjs` - 集計ロジックの Node テスト
- `vibe/std/backend_capabilities.json` - backend capability matrix 定義
- `src/tests/vibe_wasm_test.mbt` - wasm codegen テスト追加

## テスト

- `scripts/coverage_wasm_std.test.mjs` - 集計ロジックユニットテスト
- `src/tests/vibe_wasm_test.mbt`:
  - "vibe wasm compiles function alias calls"
  - "vibe wasm compiles multiple local recursive `go` helpers"
  - "vibe wasm compiles recursive helper with captured function param"
  - "vibe wasm compiles Int method-style to_double call"
- 最終実測結果 (2026-02-11):
  - `cases(total/measured/failed) = 13/13/0`
  - `execution(ok/trap) = 13/0`
  - `lines = 626/626 (100.00%)`
  - `compile_unsupported = 0`
