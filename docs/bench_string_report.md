# String Bench Report (2026-02-05)

## 概要
vibe の文字列系ベンチマークを js-string バックエンドと wasm-gc バックエンドで比較した結果。計測は `hyperfine` を使用。

## 実行コマンド
- `just bench-string-concat`
- `just bench-string-substring`
- `just bench-string-equals`

## 計測環境
- js-string: Node.js + `scripts/run_wasm_js_string_file.mjs`
- wasm-gc: wasmtime (`wasmtime run -W gc --invoke run ...`)

## 結果
### bench-string-concat
- js-string: 16.6 ms ± 0.6 ms (min 15.6 / max 18.1)
- wasm-gc: 4.3 ms ± 0.6 ms (min 3.3 / max 8.7)
- 速度差: wasm-gc が約 3.86x 速い
- 注意: 5ms 未満警告

### bench-string-substring
- js-string: 17.2 ms ± 1.2 ms (min 15.5 / max 23.3)
- wasm-gc: 4.5 ms ± 0.8 ms (min 3.4 / max 12.4)
- 速度差: wasm-gc が約 3.83x 速い
- 注意: 5ms 未満警告 / 外れ値警告

### bench-string-equals
- js-string: 17.2 ms ± 2.6 ms (min 15.8 / max 44.4)
- wasm-gc: 4.4 ms ± 0.6 ms (min 3.4 / max 11.2)
- 速度差: wasm-gc が約 3.94x 速い
- 注意: 5ms 未満警告 / 外れ値警告

## 補足
- wasm-gc の `String::equals` は早期終了 (参照一致・長さ差・先頭/末尾比較) を入れた最適化版。
- `hyperfine` の警告は、測定対象が短すぎてシェル起動コストが混ざる可能性があるため。必要なら `--shell=none` で再計測推奨。
