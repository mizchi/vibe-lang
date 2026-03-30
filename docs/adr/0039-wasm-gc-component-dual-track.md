# ADR-0039: WASM-GC Selfhost / Component Dual-Track Transition

- Date: 2026-03-30
- Status: proposed

## Context

`vibe` は中長期的には `selfhost + wasm-gc` を main execution path に寄せたい。
一方で Component Model 側は、現時点では `wasm-gc` をそのまま境界 ABI に使う前提がまだ整っていない。

既存方針:

- ADR-0010 で `--component` ターゲットを採用した
- ADR-0036 で `wasm-gc` main backend 化の gate を定義した

しかし現状の実装は、まだ `component` と `wasm-gc` を一体化していない。

- `compile_module_component` は linear-memory core wasm を組み立ててから component 化している
- component codegen の `canon lower` は option なしで固定されている
- string lift は `memory` と `cabi_realloc` を前提にしている
- selfhost component entry は `mvp` / `no-dce` は受けるが `gc` mode を持たない

上流状況もまだ移行前である。

- WebAssembly/component-model #525 は `Wasm GC Support in the Canonical ABI` の pre-proposal 段階
- maintainer コメントでも、現時点では component-model level では未実装で、当面は linear memory scratch buffer を使う案が示されている
- Wasmtime には `component-model-gc` flag は見えるが、これは compiler 側の canonical ABI 未対応を置き換えるものではない

現時点の artifact size 試算も先に押さえておく。
2026-03-30 時点の prototype build では:

- selfhost linear raw wasm: `2,194,453 B`
- selfhost linear raw wasm gzip: `622,346 B`
- selfhost Preview2 component raw wasm: `2,164,965 B`
- selfhost Preview2 component raw wasm gzip: `615,257 B`
- selfhost wasm-gc raw wasm: `536,336 B`
- selfhost wasm-gc raw wasm gzip: `160,249 B`

dual-track で `Preview2 component + wasm-gc core compiler` を持つ場合の単純合算は:

- raw: `2,701,301 B`
- gzip: `775,506 B`

この `wasm-gc` artifact は current prototype ではまだ validate / optimize を通っていない。
ただし、配布サイズのオーダー感を判断するには十分である。

## Decision

component-model の GC canonical ABI が仕様・実装ともに固まるまでは、`component` と `wasm-gc` を dual-track で進める。

採る方針:

- selfhost の本命ラインは `wasm-gc` とする
- 配布互換性ラインは `component + linear-memory canonical ABI` を維持する
- `component` は当面、GC heap object を境界に直接流さない
- `wasm-gc` は core wasm artifact / selfhost runtime として先に成熟させる

当面の operational baseline:

- `wasm-gc` 実行は `wasmtime -W gc -W function-references -W exceptions` を前提とする
- `component-model-gc` は release gate ではなく experimental investigation 用とする

single-track に切り替える条件は次の 4 点を満たしたときとする。

1. component compile path が `wasm-gc` core emitter を使える
2. component codegen が GC canonical ABI option を出力できる
   少なくとも `gc` と `core-type` を扱える
3. selfhost component entry が `gc` mode を受けられる
4. `wasm-gc` selfhost artifact が validate / optimize / runtime e2e を通過し、size と latency が release target として許容範囲に入る

それまでは、`component` を interoperability / packaging 用、`wasm-gc` を main backend 候補育成用として分離して扱う。

## Consequences

良い面:

- `selfhost + wasm-gc` への投資を止めずに進められる
- component-model の upstream 進捗に release 導線全体をブロックされない
- 配布サイズの増分を先に見積もった上で判断できる
- `component` の互換性と `wasm-gc` の性能改善を別々に前進させられる

悪い面:

- 当面は artifact と CI 観点で二重管理になる
- docs / release note / bench で backend の役割を明示し続ける必要がある
- upstream が固まるまでは `component + wasm-gc` を前提にした API surface を公開できない
