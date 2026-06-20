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
seed として固定し、stage を分けて検証すること。vibe はこの中でも Rust の
運用を主参照にし、prebuilt/fixed seed を stage0、現在 source を stage0 で
ビルドした compiler を stage1、stage1 で再ビルドした compiler を stage2 と
呼ぶ。stage2 を配布・tag 候補にし、stage3 は同一結果を確認する sanity check
として扱う。

## vibe の方針

### Seed compiler

- local gate green な状態に annotated tag を打ち、その tag から作った
  selfhost compiler artifact を seed compiler として固定する。
- seed compiler は version、git tag、source commit、artifact sha256、
  target triple、wasmtime version、build command を manifest に記録する。
- seed compiler は毎 commit 更新しない。更新は「bootstrap bump」として
  独立した PR/commit にし、下記 gate を全て通したときだけ許可する。

実装上の seed manifest は `bootstrap/selfhost/seed.json`、固定 seed artifact は
`bootstrap/selfhost/seed/` 配下に置く。stage 生成物は `_build/selfhost/`
配下に置く。2026-06-12 の cutover seed は
`selfhost-cutover-base-2026-06-12` / `39eab0519952ca72599b0b7064d00e3fbd2ac302`
に固定している。canonical dist / CLI build entry は `cli_main` を持つ
`vibe/cli/selfhost_entry.vibe` の wasm とし、各世代は次世代の compiler source を
`cli_main` 経由でビルドできるものとして扱う。CLI の argv parsing / command
dispatch は `vibe/cli/`、compiler 本体・link/check/build helper は
`vibe/compiler/` に置き、ビルド単位を分ける。

```bash
pkf run selfhost-generation-seed-info
pkf run selfhost-generation -- --stage3
scripts/selfhost_generations.sh adopt --artifact _build/selfhost/generations/<gen>/stage2.wasm
```

`adopt` は stage2 artifact を seed path にコピーし、`bootstrap/selfhost/seed.json`
の sha256 を更新する。bootstrap bump ではこの manifest 更新を独立 commit として
扱う。`pkf run selfhost-generation` は seed provenance に従い、安定した
low-level compiler entry (`vibe/compiler/selfhost_cli_support.vibe`) を flat source
化して stage を回す。`build-selfhost-dist` / `test-selfhost-cli-core` は
`vibe/cli/selfhost_entry.vibe` を使う。split CLI entry を generation default に
昇格する場合は、別の bootstrap bump として stage2/stage3、corpus、perf/RSS を
通してから manifest entry を切り替える。

### Rust-style staged build

- stage0: 固定 seed compiler。新しい compiler source をビルドするためだけに使う。
- stage1: stage0 が現在 source から作った compiler。現行 generation は固定 seed
  provenance に従う flat low-level compiler entry を使い、dist/component/CLI gate は
  `vibe/cli/` entry と `vibe/compiler/` source を使う。
- stage2: stage1 が同じ source から作った compiler。配布・tag 候補は stage2。
- stage3: optional。同じ source を stage2 で再ビルドし、stage2 と stage3 の
  挙動または artifact が一致するかを確認する。

通常開発では stage1 gate を短い feedback loop として使い、seed 更新や release
候補では stage2 gate を必須にする。stage3 は deterministic artifact 比較または
corpus parity に差分が出たときの切り分けに使う。

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

## Release asset からの bootstrap (MoonBit host build なし)

selfhost を「保証」するには、stage0 -> stage1 -> stage2 を **MoonBit host を
ビルドせずに** 回せる必要がある。完全な registry (mooncakes) と native build が
無い環境 (web/remote container 等) では `moon build src/cmd/vibe` が通らず、
従来は flatten 工程 (`emit-module-source`) が host `vibe.exe` に依存していた。

これを解消するため、selfhost に必要な 2 つの prebuilt artifact を
**GitHub Release asset** として配布し、pull して使えるようにする。

- `vibe-selfhost-<tag>.wasm` — stage0 seed compiler wasm。stock wasmtime で
  instantiate でき、`moonrun` 上で `cli_main` として動く。中身は
  `bootstrap/selfhost/seed/selfhost_compiler.wasm` (seed.json で sha256 pin)。
- `vibe-selfhost-module-source-<tag>.vibe` — flatten 済みの flat module source。
  `emit-module-source` の出力 (= committed compiler source からの決定的関数) を
  pin したもの。これがあれば flatten で host `vibe.exe` を呼ばない。
- `vibe-selfhost-seed-<tag>.json` / `release-manifest.json` / `SHA256SUMS.txt` —
  provenance と整合性メタデータ。manifest の `selfhost` block に各 asset の
  sha256 と `source_commit` が入る。

publish は `scripts/build_release_assets.sh`、取得は
`scripts/fetch_selfhost_compiler.sh` (`pkf run fetch-selfhost-compiler`)。

```bash
# release から pull + sha256 検証し、prebuilt module source の env を出す
eval "$(pkf run fetch-selfhost-compiler -- <tag> --print-env)"
# MoonBit host build を一切せず stage0 -> stage1 -> stage2 を回す
bash scripts/selfhost_generations.sh build
```

`scripts/selfhost_generations.sh` の `prepare_flat_cli_source` は
`VIBE_SELFHOST_PREBUILT_MODULE_SOURCE`(+ optional `..._SHA256`)が指定されると
regeneration を skip して pull 済み flat source を使う。未指定時の挙動
(host `vibe.exe` で regenerate) は不変。

freshness 契約: prebuilt flat source は **対応する source commit / tag 専用**。
HEAD 開発で compiler source を変えた場合は stale になるため、その場合は
従来どおり host `vibe.exe` で regenerate する。stale な artifact を使うと
flat source が現在の source と食い違い、stage1/stage2 parity 失敗として
顕在化する (fetch 側は manifest の `source_commit` を、`--adopt-seed` 時は
`seed.json` の sha256 を突き合わせて誤用を弾く)。

## Layer split

cutover 後も runner と compiler artifact は分ける。

- runner layer: `tools/moonrun_wasmtime`、wasmtime flags、cwasm cache、
  host import、component adapter。
- compiler wasm layer: `vibe/cli/` の CLI entry と `vibe/compiler/` の compiler 実装から作る dist/component/check entry。

runner layer は性能・実行基盤の都合で差し替えてよいが、canonical compiler は
portable selfhost wasm として再構築できることを gate に残す。

## Compiler wasm artifact 層の contract (#529)

compiler wasm layer には、用途の異なる 2 つの生成入口がある。両者は同じ
compiler source から作られるが、**ビルド主体が異なるため byte 列は一致しない**。
役割を取り違えないこと。

| artifact | 入口 | builder | 用途 |
| --- | --- | --- | --- |
| **dist** | `scripts/build_selfhost_dist.sh` → `_build/dist/selfhost_compiler.wasm` | MoonBit host が `vibe/cli/selfhost_entry.vibe` を直接 wasm へ compile (+ `wasm-opt -O3`) | 配布する **shipping artifact**。速い。`pkf run build-selfhost-dist`。 |
| **stage2** | `scripts/selfhost_generations.sh build` → `_build/selfhost/generations/<seed>_<sha>/stage2.wasm` | stage0(pinned seed) → stage1 → stage2 の self-reproduction。`generation.json` に `stage2_distribution_candidate` として記録 | bootstrap **再現性 candidate**。seed pin に依存し遅い。`pkf run selfhost-generation`。 |

両者は同一 compiler source なので「同じ compiler」として振る舞う必要がある。
これを **byte 列の統一ではなく contract + parity gate** で保証する:

- `scripts/test_selfhost_dist_stage2_parity.sh` (`pkf run
  test-selfhost-dist-stage2-parity`) が dist / stage2 の両 compiler で同じ
  sample を compile し、(1) 出力 wasm の `vibe.abi` custom section 一致、
  (2) 両方が 42 を返す挙動一致、(3) 既定では出力 wasm の byte 一致
  (`VIBE_DIST_PARITY_REQUIRE_HASH=0` で behavioral parity に緩和) を assert する。
- この gate は `release-selfhost-gates` に含まれる。

### `vibe.abi` custom section contract

selfhost codegen (`vibe/compiler/codegen/wasm_emit/metadata.vibe` ::
`emit_vibe_abi_custom_section`、呼び出しは
`vibe/compiler/codegen/wasi/linked_compile.vibe`) は、**自身が生成する** wasm に
custom section `vibe.abi` を埋め込む。これが artifact 層の ABI 契約メタデータ。

- section name: `vibe.abi`
- payload (ASCII):

  ```
  version=1
  host_import_abi=<abi>
  ```

- `version` は contract schema。互換性を壊す変更で bump する。
- `host_import_abi` は wasm が前提とする host import ABI (既定 `raw`)。
  runner layer (`scripts/run_wasm_vibe_host_runner.sh` 等の
  `VIBE_SELFHOST_IMPORT_ABI`) が供給すべき host import の選択に対応する。
- これは compiler が **出力する program wasm** に付くものであり、compiler
  binary 自体には付かない。MoonBit host (`src/`) codegen は `vibe.abi` を
  emit しない。そのため dist / stage2 の **compiler binary** 同士で `vibe.abi`
  を比較しても意味がなく、parity gate は両 compiler が **生成した output** の
  `vibe.abi` を突き合わせる (上記)。

runner layer が出力 wasm を instantiate する際は、`vibe.abi` の
`host_import_abi` を見てどの host import set を提供するかを決められる。section
が無い wasm は host import を必要としない pure module、または非 selfhost 生成物
として扱う。

## MoonBit `src/` の退役

`src/` は selfhost cutover 後、legacy bootstrap/fallback 層へ縮退する。
新機能、bugfix、CLI 挙動変更、builtin 追加は `src/` に入れず、
`vibe/compiler/` / `vibe/cli/` 側で実装する。削除は一度に行わず、次の順に進める。

1. seed tag と manifest を固定する。2026-06-12 cutover seed は完了済み。
2. default CLI build/run/check/test を selfhost wasm 経路へ向ける。新規 CLI 実装は
   `vibe/cli/` と `vibe/compiler/` 側で行う。
3. CI で seed -> stage1 -> stage2 と corpus/perf/RSS gate を継続 green にする。
4. MoonBit `src/` を runner/fallback に必要な最小限へ縮小する。
5. fallback が不要になった時点で archive または削除する。

break-glass として `src/` を変更する場合は、通常 feature commit とは分け、
bootstrap 復旧または退役作業であることを commit message / PR description に
明記する。
