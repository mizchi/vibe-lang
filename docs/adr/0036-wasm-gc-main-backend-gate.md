# ADR-0036: WASM-GC Main Backend Graduation Gate

- Date: 2026-03-27
- Status: accepted

## Context

`0.1.0` の release profile では `wasm-gc` backend は experimental とした。
一方で `src/runtime_compile` には `compile_module_wasm_gc` が公開され、
`vibe_compile_wasi --wasm` は `wasm-gc` 優先の導線をすでに持っている。

この状態だと、

- docs 上は experimental / fixture-focused の記述が残る
- 実装上は部分的に mainline 扱いが先行する
- どの時点で `wasm-gc` を main backend に昇格できるかが不明確

というズレがある。

`wasm-gc` main 化は感覚ではなく、専用 acceptance suite で判定する。

## Decision

`wasm-gc` を main backend に昇格する最低条件を、専用 native e2e suite の green とする。

判定コマンド:

```bash
just test-wasm-gc-mainlane-e2e
```

対象 suite:

- `src/tests/vibe_wasm_gc_mainlane_e2e_test.mbt`

初期 gate で必須とするケース:

- closure capture が wasmtime 上で end-to-end 実行できる
- 関数を返す higher-order function が end-to-end 実行できる
- `for-in` lowering が compile-only ではなく runtime でも正しく動く
- string lowering / builtin runtime が end-to-end で動く

この suite が green になった時点で、

- `wasm-gc` は main backend 候補として扱ってよい
- `--wasm` の既定値切り替えを実施してよい

あわせて同一 change か直後の change で以下を行う。

- `just test` / CI shard に suite を組み込む
- docs の experimental / fixture-focused 記述を更新する

## Consequences

良い面:

- `wasm-gc` main 化の判断基準が明文化される
- closure / HOF / collection / string runtime という実利用に近い面を gate 化できる
- roadmap と実装導線のズレを TODO と test で追跡できる

悪い面:

- suite が green になるまでは `wasm-gc` は部分的に mainline へ露出していても正式昇格できない
- gate を増やす分、native wasmtime e2e の保守コストが増える
