# ADR-0001: MoonBit を実装言語として採用する

- Date: 2026-02-16
- Status: accepted

## Context

vibe 言語のコンパイラ・ランタイムを実装する言語を選定する必要があった。候補として Rust, OCaml, TypeScript, MoonBit などが考えられた。vibe は WASM を主要なターゲットとしており、コンパイラ自体も WASM 上で動作させたいという要件があった。

## Decision

MoonBit を実装言語として採用する。コンパイラ（パーサ、型チェッカ、codegen）、インタプリタ、IDE ツールをすべて MoonBit で記述する。

理由:
- MoonBit は WASM-GC / JS / Native の3ターゲットをサポートし、コンパイラ自体をブラウザ・CLI・WASI のいずれでも実行可能にできる
- 代数的データ型・パターンマッチなどコンパイラ実装に適した言語機能を持つ
- `moon test` によるスナップショットテスト・ベンチマーク基盤が組み込まれている

## Consequences

- コンパイラが `wasm-gc` ターゲットで WASM として配布可能になった（`wasm/vibe/vibe.wasm`）
- JS バインディング経由で Deno/Node.js からも利用可能
- MoonBit 自体が発展途上のため、言語仕様変更への追従コストが生じる
