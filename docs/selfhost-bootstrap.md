# Selfhost Bootstrap Policy

この文書は、vibe compiler を selfhost canonical に移すときの seed compiler
運用を固定する。目的は、HEAD の compiler source が常に「直前の安定
compiler から再構築できる」状態を保ちつつ、新しい言語機能へ段階的に移行すること。

## 背景

selfhost compiler は、自分自身をビルドできるようになった後も、更新の起点に
なる compiler binary が必要になる。既存言語でもこの境界は明示されている。

- Rust は prebuilt stage0 compiler を起点に stage1 を作り、stage1 で
  stage2 を作る。stage3 は同じ結果になるかを確認する optional sanity check。
  <https://rustc-dev-guide.rust-lang.org/building/bootstrapping/what-bootstrapping-does.html>
- Go は Go toolchain 自体が Go で書かれているため、source build には
  bootstrap 用の Go compiler が必要。Go 1.N は原則として過去の安定 Go
  compiler で bootstrap する。
  <https://go.dev/doc/install/source>
- GHC は installed GHC を stage0/bootstrap compiler とし、stage1、stage2、
  optional stage3 に分けてビルドする。
  <https://ghc.gitlab.haskell.org/ghc/doc/users_guide/using.html>

共通しているのは、開発中の HEAD をいきなり信頼せず、既知の compiler を
seed として固定し、stage を分けて検証すること。

## vibe の方針

### Seed compiler

- 現在の local gate green な状態に annotated tag を打ち、その tag から作った
  selfhost compiler artifact を seed compiler として固定する。
- seed compiler は version、git tag、source commit、artifact sha256、
  target triple、wasmtime version、build command を manifest に記録する。
- seed compiler は毎 commit 更新しない。更新は「bootstrap bump」として
  独立した PR/commit にし、下記 gate を全て通したときだけ許可する。

### Staged build

- stage0: 固定 seed compiler。新しい compiler source をビルドするためだけに使う。
- stage1: stage0 が現在の `vibe/compiler/` source から作った compiler。
- stage2: stage1 が同じ source から作った compiler。配布・tag 候補は stage2。
- stage3: optional。同じ source を stage2 で再ビルドし、stage2 と stage3 の
  挙動または artifact が一致するかを確認する。

### Gate

bootstrap bump は最低限、以下を満たす。

- `release-selfhost-gates` が green。
- perf KPI: TOTAL compile <= 2.5x、TOTAL check <= 1.33x。
- peak RSS: compile/check とも <= 2.0x。
- corpus check parity: REAL gap = 0。
- portable one-shot wasm path と wasmtime/cwasm accelerated path の correctness が一致。

### 新機能の入れ方

新しい syntax や型システム機能を compiler source で使うときは、次の順番を守る。

1. seed compiler が理解できる既存 subset で、新機能の parser/checker/codegen を実装する。
2. stage1/stage2 gate を通し、新機能を含む compiler を tag 可能にする。
3. bootstrap bump で seed compiler を更新する。
4. その後に初めて、compiler source 自体を新機能の syntax へ移行する。

つまり「新機能を実装する commit」と「compiler source が新機能を使い始める
commit」は分ける。これにより、常に固定 seed から HEAD を復元できる。

## Layer split

cutover 後も runner と compiler artifact は分ける。

- runner layer: `tools/moonrun_wasmtime`、wasmtime flags、cwasm cache、
  host import、component adapter。
- compiler wasm layer: `vibe/compiler/` から作る dist/component/check entry。

runner layer は性能・実行基盤の都合で差し替えてよいが、canonical compiler は
portable selfhost wasm として再構築できることを gate に残す。

## MoonBit `src/` の退役

`src/` は selfhost cutover 後、bootstrap/fallback 層へ縮退する。削除は一度に
行わず、次の順に進める。

1. seed tag と manifest を固定する。
2. default CLI build/run/check/test を selfhost wasm 経路へ向ける。
3. CI で seed -> stage1 -> stage2 と corpus/perf/RSS gate を継続 green にする。
4. MoonBit `src/` を runner/fallback に必要な最小限へ縮小する。
5. fallback が不要になった時点で archive または削除する。
