# ADR-0033: Selfhost 0.1.0 Release Profile

- Date: 2026-03-22
- Status: accepted

## Context

0.1.0 の目標は「selfhost compiler が実用的な `.wasm` artifact として配布できる」ことにある。
ただし、現状の selfhost artifact は複数系統に分かれている。

- core compiler wasm: `just build-selfhost-dist`
- Preview2 component package
- command component
- direct filesystem component
- check 用 component / command artifact
- GC backend artifact

これらを全部同列に扱うと、release gate と supported surface が曖昧になる。
また、現在もっとも安定しているのは compile-centric な core compiler wasm であり、
`build_selfhost_dist.sh` と `test_selfhost_cli_core.sh` もこの系統を中心に組まれている。

一方で、`check` と `compile` を完全に同じ単一 artifact に統合した「全部入り selfhost CLI wasm」は、
0.1.0 時点ではまだ product 契約として固定されていない。

## Decision

0.1.0 の canonical selfhost artifact は、`just build-selfhost-dist` が生成する
single-file core compiler wasm とする。

- canonical artifact:
  `_build/dist/selfhost_compiler.wasm`
- canonical entry:
  `vibe/compiler/selfhost_cli_core_entry.vibe`
- canonical build path:
  `just build-selfhost-dist`

0.1.0 の primary supported surface は、この artifact が提供する
compile-centric selfhost compiler とする。

- source file から wasm を生成できること
- linked debug build を生成できること
- 生成した sample wasm を実行して妥当な結果を返せること
- selfhost cutover / selfbuild / parity gate に耐えること

以下の artifact は 0.1.0 では secondary artifact とする。
重要な gate ではあるが、canonical release artifact ではない。

- Preview2 component package
- command component
- direct filesystem component
- selfhost check component / command artifact
- GC backend artifact

0.1.0 では、linear/WASM 系 artifact を正式対象にし、GC backend は experimental 扱いとする。

また、「check / compile / run / build の全導線を 1 個の wasm artifact に統合した
all-in-one selfhost CLI」は、0.1.0 の必須条件には含めない。
これは post-0.1.0 の product work として別管理する。

## Consequences

良い面:

- release gate の主語が明確になる
- `release-selfhost-gates` と `build-selfhost-dist` の整備に集中できる
- `Bytes` / `BytesView` や parity の残差を、canonical artifact 基準で判断できる
- Preview2 / component / check artifact は parity と将来 product の検証レーンとして維持できる

悪い面:

- 0.1.0 時点では「全部入り単一 selfhost CLI wasm」はまだ正式契約にならない
- `check` 系 artifact は重要だが canonical release artifact ではないため、説明を明示しないと誤解されやすい
- component 系を主対象にしたいユーザーには、0.1.0 の物語がやや保守的に見える
