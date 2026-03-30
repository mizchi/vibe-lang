# ADR-0040: Checker / Codegen Contract Boundary

- Date: 2026-03-30
- Status: proposed

## Context

`vibe` の compile path は現在、実質的に `parse -> typecheck -> codegen` が一体で進んでいる。
public CLI としてはこの流れ自体は妥当だが、内部設計としては次の問題が残っている。

- checker 実装と codegen 実装の境界が曖昧
- `runtime_compile` が checker の内部表現に引きずられやすい
- selfhost / host / cache / future daemon で再利用する contract が明示されていない
- checker をリンクしない codegen build flavor を設計上保証できない

artifact size の試算でも、checker は十分に大きい塊になっている。
2026-03-30 時点の stage1 host artifact では:

- `vibe_compile_wasi.wasm`: `2,505,441 B`
- `vibe_compile_wasi.wasm.gz`: `907,568 B`
- `vibe_check_wasi.wasm`: `1,233,780 B`
- `vibe_check_wasi.wasm.gz`: `426,055 B`

source 側の粗い見積もりでも checker は約 `21.2k LOC` ある。
このため、今後 `wasm-gc` mainline、selfhost、compile/check 分離、artifact flavor 最適化を進めるなら、
まず checker と codegen の間に安定 contract を置く必要がある。
この ADR は issue #73 の設計方針を固定するためのものとする。

ここで重要なのは「通常の compile コマンドが checker を通るかどうか」ではない。
重要なのは、**設計上は checker 実装本体をリンクしなくても codegen package が成立する**ことを保証することである。

## Decision

checker と codegen の間に、専用の contract layer を導入する。

当面の呼称は `CheckedModule` または `TypedModule` とし、最終的な名前よりも責務分離を優先する。

この contract layer に含めるもの:

- codegen に必要な module-level semantic information
- 解決済みの symbol / ref / binding 関係
- codegen が参照する型・関数・ctor の確定情報
- lowering 後に backend が共有して使うべき最小限の shape

この contract layer に含めないもの:

- checker の診断生成ロジック
- lint / warning policy
- human-readable diagnostics rendering
- checker 内部の探索・推論途中状態

依存方向は次の形に固定する。

- checker 実装は contract layer を生成する
- codegen 実装は contract layer のみを入力として受ける
- `runtime_compile` と selfhost compile path は checker 内部型ではなく contract layer を参照する

この決定は default CLI の契約を変更しない。

- `compile` は引き続き check-before-emit でよい
- `check` は引き続き diagnostics を返してよい

ただし内部構造としては、

- checker-less codegen build が成立する
- compile/check artifact を別 flavor として扱える
- precompiled IR / cache / daemon で再利用できる

状態を目標にする。

移行順は次の通りとする。

1. codegen が実際に必要としている semantic data を列挙する
2. その最小集合を contract layer に切り出す
3. checker が contract layer を返す形へ寄せる
4. codegen から checker 実装本体への依存を除去する
5. host/selfhost compile path を同じ contract layer に揃える

## Consequences

良い面:

- checker と codegen の責務境界が明文化される
- checker-less codegen build flavor を設計上保証できる
- selfhost / host / cache / precompiled IR が同じ contract を共有できる
- `wasm-gc` only build や checker artifact 分離の前提が整う

悪い面:

- 移行期間は checker 内部表現と contract layer の二重管理が発生する
- codegen が必要とする情報を過不足なく切り出す設計コストがある
- contract を急ぎすぎると checker internals をそのまま露出して固定化する危険がある

この ADR は「checker と codegen の境界を contract layer で固定する」ことを決める。
diagnostics 分離と `wasm-gc` only build flavor は、それぞれ別 issue で追う。
