# 0.1.0 Product Bundle Size Investigation

Date: 2026-03-26

初回調査時点では `scripts/monitor_wasm_bundle_size.sh` に non-fatal regression が残っていたが、
2026-03-26 の整理で warning は 0 件まで解消した。

## Initial Regressions

| Path | Budget | Current | Delta | Notes |
|---|---:|---:|---:|---|
| `examples/async.vibe` | 821 | 954 | +133 | source diff なし。compiler/runtime growth 寄り |
| `examples/basics.vibe` | 1515 | 1624 | +109 | source diff なし。string-heavy example |
| `examples/perform_handle.vibe` | 621 | 645 | +24 | source diff なし。effect/codegen growth 寄り |

## Classification

### 1. Updated as budget follow-up

次の 5 件は current artifact に追従して product budget を更新済み。

- `examples/base64.vibe`
- `bench/bundle_size/consumer_option_core.vibe`
- `examples/string_basic.vibe`
- `examples/syntax.vibe`
- `examples/effects.vibe`

`examples/effects.vibe` は source diff 自体はないが、
compiler-side の mirror case `bench/compiler_size/cases/effects.vibe` が
すでに `440` budget なので、product 側も stale budget 扱いに寄せた。

### 2. Source changed

次の 2 件は source 自身が変わっている。

- `examples/string_basic.vibe`
  - raw string case が `r"hello\nworld"` から `"hello\\nworld"` へ変更
- `examples/syntax.vibe`
  - `run` 追加と formatting/structure change を含む

現時点ではどちらも intent を受け入れて product budget を更新済み。

### 3. Likely compiler/runtime growth

次の 3 件は source diff が見えず、まだ product budget を上げる根拠が弱い。

- `examples/async.vibe`
- `examples/basics.vibe`
- `examples/perform_handle.vibe`

## Strong Signal

`+109` が複数ケースに共通している。

- `examples/basics.vibe`
- `examples/string_basic.vibe`
- `bench/bundle_size/consumer_option_core.vibe`

この値は、個別 source より共通 helper / prelude / codegen overhead の増分を疑うべきパターン。
特に string-heavy examples では `[vibe/prelude/string.vibe](vibe/prelude/string.vibe)` に
`String::drop/head/init/last/tail/take/equals` などの wrapper 追加があり、
`wasm-no-dce` monitor ではこれが効いている可能性が高い。

## Recommendation

1. budget-only stale / accepted source change の 5 件は更新済み
2. source diff なしの 3 件は、0.1.0 前に「許容 budget update」か「real regression fix」かを決める
   - `examples/async.vibe`
   - `examples/basics.vibe`
   - `examples/perform_handle.vibe`

## Final Resolution

最終的な解決は example の縮小ではなく、生成 wasm 側の実回帰修正だった。

入れた修正は 3 つ。

- thin prelude wrapper の未使用関数を emit 前に除去
  - `eq(...)` の薄い wrapper が DCE を抜けて残るケースを止めた
- top-level const の static fold と dead let 除去
  - `Option` helper や `if/eq` の定数分岐を compile 時に潰す
- numeric `eq/__eq/assert_eq` を tagged int fast path に切り替え
  - generic tagged compare が `examples/basics.vibe` / `examples/async.vibe` を膨らませていた主因

特に最後の fast path 修正で、probe は次まで縮んだ。

- `let check = (a: Int, b: Int) -> Int { assert_eq(a, b); 1 }`
  - `836 bytes -> 112 bytes`

product example の current size も、source を削らずに budget 内へ戻った。

| Path | Current |
|---|---:|
| `examples/async.vibe` | 230 |
| `examples/basics.vibe` | 831 |
| `examples/perform_handle.vibe` | 581 |
| `bench/bundle_size/consumer_option_core.vibe` | 82 |

確認:

- `bash scripts/bench_bundle_size.sh` → `bundle-size: all entries are within budget.`
