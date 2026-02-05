# Codegen Bench Report (2026-02-05)

## 概要
`sample_numeric_script` (Int/Float/Double を含む) を使って、`emit_module_wasm_gc` と
`emit_module_wasm_js_string` のコード生成速度を比較した簡易ベンチ結果。
MoonBit の `moon bench` で計測。

## 実行コマンド
- `moon bench`

## ベンチ対象
- `bench: codegen.emit_module_wasm_gc.numeric`
- `bench: codegen.emit_module_wasm_js_string.numeric`

## 結果
- wasm-gc (numeric): 17.23 µs ± 0.34 µs (min 16.88 / max 17.92)
- wasm-js-string (numeric): 72.61 µs ± 2.21 µs (min 69.50 / max 75.46)
- 速度差: wasm-gc が約 4.2x 速い

## 補足
- 本ベンチは「コード生成速度」のみを測定。実行時速度は含まない。
- 入力スクリプトは `src/benches/fixtures.mbt` の `sample_numeric_script`。
