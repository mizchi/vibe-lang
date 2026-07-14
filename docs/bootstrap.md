# Bootstrap Policy

この文書は、vibe compiler の自己コンパイル (self-compilation) を支える seed
compiler 運用を固定する。目的は、HEAD の compiler source が常に「直前の安定
compiler から再構築できる」状態を保ちつつ、新しい言語機能へ段階的に移行すること。

## 背景

compiler は、自分自身をビルドできるようになった後も、更新の起点に
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
  compiler artifact を seed compiler として固定する。
- seed compiler は version、git tag、source commit、artifact sha256、
  target triple、wasmtime version、build command を manifest に記録する。
- seed compiler は毎 commit 更新しない。更新は「bootstrap bump」として
  独立した PR/commit にし、下記 gate を全て通したときだけ許可する。

実装上の seed manifest は `bootstrap/seed.json`、固定 seed artifact は
`bootstrap/seed/` 配下に置く。stage 生成物は `_build/selfhost/`
配下に置く。2026-06-12 の cutover seed は
`selfhost-cutover-base-2026-06-12` / `39eab0519952ca72599b0b7064d00e3fbd2ac302`
に固定している。canonical dist / CLI build entry は `cli_main` を持つ
`lib/@vibe/cli/entry.vibe` の wasm とし、各世代は次世代の compiler source を
`cli_main` 経由でビルドできるものとして扱う。CLI の argv parsing / command
dispatch は `lib/@vibe/cli/`、compiler 本体・link/check/build helper は
`lib/@vibe/compiler/` に置き、ビルド単位を分ける。

```bash
pkf run selfhost-generation-seed-info
pkf run selfhost-generation-status   # read-only: seed pin + latest generation
pkf run selfhost-generation -- --stage3
scripts/generations.sh adopt --artifact _build/selfhost/generations/<gen>/stage2.wasm
```

`status` (= `scripts/generations.sh status`) は rebuild せずに、pin
された seed (sha 検証付き)、現在の source commit、直近の generation manifest
(stage0..stage3 の sha と `stage3_equal_stage2`) を一覧する。stage0 -> stage1 ->
stage2 -> bootstrap bump の流れを追跡したいときの入口にする。

`adopt` は stage2 artifact を seed path にコピーし、`bootstrap/seed.json`
の sha256 を更新する。bootstrap bump ではこの manifest 更新を独立 commit として
扱う。`pkf run selfhost-generation` は seed provenance に従い、安定した
low-level compiler entry (`lib/@vibe/compiler/cli_support.vibe`) を flat source
化して stage を回す。`build-selfhost-dist` / `test-selfhost-cli-core` は
`lib/@vibe/cli/entry.vibe` を使う。split CLI entry を generation default に
昇格する場合は、別の bootstrap bump として stage2/stage3、corpus、perf/RSS を
通してから manifest entry を切り替える。

### Rust-style staged build

- stage0: 固定 seed compiler。新しい compiler source をビルドするためだけに使う。
- stage1: stage0 が現在 source から作った compiler。現行 generation は固定 seed
  provenance に従う flat low-level compiler entry を使い、dist/component/CLI gate は
  `lib/@vibe/cli/` entry と `lib/@vibe/compiler/` source を使う。
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

self-compilation を「保証」するには、stage0 -> stage1 -> stage2 を **MoonBit host を
ビルドせずに** 回せる必要がある。完全な registry (mooncakes) と native build が
無い環境 (web/remote container 等) では `moon build src/cmd/vibe` が通らず、
従来は flatten 工程 (`emit-module-source`) が host `vibe.exe` に依存していた。

これを解消するため、self-compilation に必要な 2 つの prebuilt artifact を
**GitHub Release asset** として配布し、pull して使えるようにする。

- `vibe-selfhost-<tag>.wasm` — stage0 seed compiler wasm。stock wasmtime で
  instantiate でき、`moonrun` 上で `cli_main` として動く。中身は
  `bootstrap/seed/selfhost_compiler.wasm` (seed.json で sha256 pin)。
- `vibe-selfhost-module-source-<tag>.vibe` — flatten 済みの flat module source。
  `emit-module-source` の出力 (= committed compiler source からの決定的関数) を
  pin したもの。これがあれば flatten で host `vibe.exe` を呼ばない。
- `vibe-selfhost-seed-<tag>.json` / `release-manifest.json` / `SHA256SUMS.txt` —
  provenance と整合性メタデータ。manifest の `selfhost` block に各 asset の
  sha256 と `source_commit` が入る。

publish は `scripts/build_release_assets.sh`、取得は
`scripts/fetch_compiler.sh` (`pkf run fetch-selfhost-compiler`)。

```bash
# release から pull + sha256 検証し、prebuilt module source の env を出す
eval "$(pkf run fetch-selfhost-compiler -- <tag> --print-env)"
# MoonBit host build を一切せず stage0 -> stage1 -> stage2 を回す
bash scripts/generations.sh build
```

`scripts/generations.sh` の `prepare_flat_cli_source` は
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

- runner layer: `runtime/moonrun_wasmtime`、wasmtime flags、cwasm cache、
  host import、component adapter。
- compiler wasm layer: `lib/@vibe/cli/` の CLI entry と `lib/@vibe/compiler/` の compiler 実装から作る dist/component/check entry。

runner layer は性能・実行基盤の都合で差し替えてよいが、canonical compiler は
portable な compiler wasm として再構築できることを gate に残す。

## Compiler wasm artifact 層の contract (#529)

compiler wasm を作る入口は 2 つある。両者は **同じ compiler source** を入力に
するが、**builder が異なる**ため成果物の byte は一致しない。これは設計上の前提
であり、等価性は byte 統一ではなく contract + parity gate で保証する。

| artifact | builder | 出力先 | 役割 |
|---|---|---|---|
| dist | `scripts/build_selfhost_dist.sh` | `_build/dist/selfhost_compiler.wasm` (+ `_raw`) | MoonBit host-compiled の shipping artifact。配布・実行用。wasm-opt `-O3` を通す。 |
| stage2 | `scripts/generations.sh build` | `_build/selfhost/generations/<ts>/stage2.wasm` | pinned seed から self-reproduce した candidate。bootstrap bump 判断用。 |

- dist は host (`src/`) MoonBit codegen の出力、stage2 は compiler 自身の wasm
  codegen の出力なので、**compiler binary 同士の byte 比較は意味がない**。生成入口を
  一本化せず役割で分けるのが canonical な扱い。
- `scripts/generations.sh status` で seed pin / source commit / 直近
  generation manifest (stage0..stage3 の sha, stage3==stage2) を rebuild 無しで
  確認できる。stage0 → stage1 → stage2 → bump の追跡入口。

### `vibe.abi` custom section contract

compiler の codegen (`lib/@vibe/compiler/codegen/wasm_emit/metadata.vibe::emit_vibe_abi_custom_section`)
は **生成する program wasm** に custom section `vibe.abi` を埋め込む。これは
compiler binary 自身にも (compiler が自分自身を compile した結果なので) 載る。

```
section id 0 (custom), name "vibe.abi", payload:
  version=1
  host_import_abi=<abi>
```

- `version` は section レイアウトの版。
- `host_import_abi` は runner 層 (`VIBE_SELFHOST_IMPORT_ABI`) の host import 選択に
  対応する (現状 `raw`)。runner はこの値で import の解決方法を切り替える。
- host (`src/`) codegen はこの section を emit しない。したがって host-compiled な
  dist binary 自体には載らないが、**dist / stage2 のどちらで compile しても、出力
  program wasm の `vibe.abi` は一致しなければならない** (= ABI contract)。

### parity gate

`scripts/test_dist_stage2_parity.sh`
(`pkf run test-selfhost-dist-stage2-parity`) が contract を検証する。dist / stage2
両 compiler で同一 sample を compile し、

1. 出力 program wasm の `vibe.abi` 一致、
2. 両方 42 を返す behavioural parity、
3. 既定で出力 wasm の byte 一致 (`VIBE_DIST_PARITY_REQUIRE_HASH=0` で behavioural +
   ABI のみに緩和)

を assert する。`--self-test` は build 無しで pinned seed wasm に対し `vibe.abi`
抽出ロジックだけを検証する (CI/build 不要の smoke)。

gate は `release-selfhost-gates` に組み込まれ、`pkf run selfhost-gate`
(`trial_gate.sh`) の本流で走る。selfhost gate は本 gate の直前に
`generations.sh build --stage3` で stage2/stage3 を生成するため、
gate は既定 (`VIBE_DIST_PARITY_REUSE_STAGE2=1`) でその stage2 を再利用し、
dist のみ fresh に build して比較する。stage2 再生成が前提なので、初回 green は
seed が build 環境にある状態で確認する。

## MoonBit `src/` の退役

`src/` は selfhost cutover 後、legacy bootstrap/fallback 層へ縮退する。
新機能、bugfix、CLI 挙動変更、builtin 追加は `src/` に入れず、
`lib/@vibe/compiler/` / `lib/@vibe/cli/` 側で実装する。削除は一度に行わず、次の順に進める。

1. seed tag と manifest を固定する。2026-06-12 cutover seed は完了済み。
2. default CLI build/run/check/test を compiler wasm 経路へ向ける。新規 CLI 実装は
   `lib/@vibe/cli/` と `lib/@vibe/compiler/` 側で行う。
3. CI で seed -> stage1 -> stage2 と corpus/perf/RSS gate を継続 green にする。
4. MoonBit `src/` を runner/fallback に必要な最小限へ縮小する。
5. fallback が不要になった時点で archive または削除する。

break-glass として `src/` を変更する場合は、通常 feature commit とは分け、
bootstrap 復旧または退役作業であることを commit message / PR description に
明記する。
