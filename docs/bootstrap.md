# Bootstrap Policy

この文書は、vibe compiler の自己コンパイル (self-compilation) を支える seed
compiler 運用を固定する。目的は、HEAD の compiler source が常に「直前の安定
compiler から再構築できる」状態を保ちつつ、新しい言語機能へ段階的に移行すること。

## Build gotcha (read before iterating on the compiler)

`scripts/generations.sh build` and `generate_bundle.sh` reuse the existing
generated flat module source
(`lib/@vibe/compiler/_cli_adapter_module_source.vibe`, non-tracked) by
default (`build_adapter_module_source`, gated on
`VIBE_REGEN_MODULE_SOURCE`). Editing compiler source files therefore has
**no effect** on a build until the flat module source is regenerated.
Always build with:

```bash
VIBE_REGEN_MODULE_SOURCE=1 bash scripts/generations.sh build
```

`scripts/compiler_gate.sh` regenerates and checks sync, so it catches a
stale module source — but a plain `build` will silently use the old one.

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
pkf run generation-seed-info
pkf run generation-status   # read-only: seed pin + latest generation
pkf run generation -- --stage3
scripts/generations.sh adopt --artifact _build/selfhost/generations/<gen>/stage2.wasm
```

`status` (= `scripts/generations.sh status`) は rebuild せずに、pin
された seed (sha 検証付き)、現在の source commit、直近の generation manifest
(stage0..stage3 の sha と `stage3_equal_stage2`) を一覧する。stage0 -> stage1 ->
stage2 -> bootstrap bump の流れを追跡したいときの入口にする。

`adopt` は stage2 artifact を seed path にコピーし、`bootstrap/seed.json`
の sha256 を更新する。bootstrap bump ではこの manifest 更新を独立 commit として
扱う。`pkf run generation` は seed provenance に従い、安定した
low-level compiler entry (`lib/@vibe/compiler/cli_support.vibe`) を flat source
化して stage を回す。`test-cli-core` は
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

- `pkf run full-gate` が green (staged generation + `scripts/compiler_gate.sh`)。
- 新 seed を stage0 に据えて回した generation で `stage3 == stage2`。
  自分自身を再生産する seed なら `stage0 == stage1 == stage2 == stage3` に
  なる (fixpoint) — bump 候補としてはこれが最も強い状態。
- `bash scripts/ensure_generated.sh --force` が通り、その後 `--check` が ok。
- `scripts/check_vibe_fmt.sh` が clean。
- unit battery (`scripts/unit_test_runner.sh`) が green。

> **Historical:** かつてここには `release-gates` に加えて4条件 — perf KPI
> (TOTAL compile <= 2.5x、TOTAL check <= 1.33x)、peak RSS (compile/check とも
> <= 2.0x)、corpus check parity (REAL gap = 0)、portable one-shot と
> wasmtime/cwasm accelerated の correctness 一致 — が並んでいた。**4つとも
> MoonBit host 時代の計測基盤に依存していて、host 退役 (#594) 以降は実行でき
> ない**。2026-08-04 の bump で実際に確認した:
>
> - 前3者: `scripts/gate.sh --post-generation` は `compiler_gate.sh` へ
>   redirect するだけになっている。`release-gates` task も同じく
>   `compiler_gate.sh` の alias。
> - 最後の1つ: `scripts/test_moonrun_wt_daemon_parity.sh` は
>   `_build/wasm/{opt,release,debug}/.../vibe_check_wasi.wasm` を探していたが、
>   これは MoonBit host の `cmd/vibe_check_wasi` パッケージの成果物で、
>   repo 内にこれを生成するものは無かった。実行すると
>   `no stage1 check wasm found` で必ず落ちる dead task だったため、
>   2026-08-04 の MoonBit dead-code 退役でスクリプトごと削除した。

### 新機能の入れ方

新しい syntax や型システム機能を compiler source で使うときは、次の順番を守る。

1. seed compiler が理解できる既存 subset で、新機能の parser/checker/codegen を実装する。
2. stage1/stage2 gate を通し、新機能を含む compiler を tag 可能にする。
3. bootstrap bump で seed compiler を更新する。
4. その後に初めて、compiler source 自体を新機能の syntax へ移行する。

つまり「新機能を実装する commit」と「compiler source が新機能を使い始める
commit」は分ける。これにより、常に固定 seed から HEAD を復元できる。

## Seed artifact 配布 (GitHub Release, #1000 part 2)

seed バイナリ (~1.4MB) を bootstrap bump のたびに git commit で丸ごと
差し替える運用は、差分の効かないバイナリを積み重ねるだけで `.git` を圧迫する
一方だった (20 回のバイナリ commit で `.git` 824MB)。これを GitHub Release
asset として配布する方式に切り替える。

**ロールアウトは2段階**: `workflow_dispatch` で起動する `seed-release.yml`
自体が default branch 上に無いと GitHub は dispatch を受け付けないため
(タグ push 済みの branch を指定しても `workflow not found on the default
branch` になる)、まず現状どおり `bootstrap/seed/compiler.wasm` を
git 管理下に置いたままこの節の仕組み一式 (workflow・スクリプト群) だけを
merge し、`seed-release` workflow が使えるようになってから最初の release
(`seed/map-from-pairs-2026-07-17`) を実際に発行し、その後に
`bootstrap/seed/compiler.wasm` を `git rm --cached` + `.gitignore` で
実際に untrack する (part 2b, 別 commit/PR)。CI を一切壊さずに移行する
ための順序であり、以下の記述は **untrack 後の定常状態** を説明する。

`bootstrap/seed.json` には artifact の sha256 と、それを取得する release
タグ (`seed.tag`) だけを記録する (untrack 後)。実体は初回アクセス時に
フェッチしてローカルにキャッシュする。

- `scripts/ensure_seed.sh` — `bootstrap/seed.json` の pin と on-disk の
  `bootstrap/seed/compiler.wasm` を比較し、無いか sha256 が食い違っていれば
  `scripts/fetch_compiler.sh --adopt-seed` で取得する。一致していれば何もせず
  即終了 (ネットワークに触らない)。`scripts/generations.sh` の
  `verify_seed_artifact` から自動的に呼ばれるので、通常は明示的に叩く必要はない
  (`VIBE_GENERATION_AUTO_FETCH_SEED=0` で無効化できる — CI のオフライン診断など、
  意図的にフェッチさせたくない場合のみ使う)。
- CI は `actions/cache` (`bootstrap/seed.json` の hash をキーにする) を
  `scripts/ensure_seed.sh` の前段に置き、ウォームランナーはネットワーク不要で
  済むようにする。取得に失敗した場合は **即座に fail** する — 古い/誤った
  seed を黙って使うより安全なため。エラーメッセージが tag/URL と
  `--from-dir` (air-gapped ミラー用) の使い方を案内する。

### Release タグ体系

- 製品リリース: `v*` (例 `v0.3.0`)。`.github/workflows/release.yml` が発火し、
  `scripts/build_release_assets.sh` が publish する通常の GitHub Release。
- bootstrap-bump seed リリース: `seed/<name>` (例
  `seed/map-from-pairs-2026-07-17`、`<name>` は既存の `seed.name` 命名を踏襲)。
  `.github/workflows/seed-release.yml` が発火し、
  `scripts/build_seed_release_assets.sh` が publish する。バージョン概念が
  無い (製品リリースではない) ので semver チェックは無く、**prerelease** として
  作成する — 通常の Releases 一覧で `v*` と混ざって読みにくくならないように。

どちらのリリースも同じ artifact trio を含む (共有ロジックは
`scripts/build_compiler_seed_assets.sh`):

- `vibe-compiler-<tag>.wasm` — stage0 seed compiler wasm。stock wasmtime で
  instantiate でき、`cli_main` として動く。中身は `bootstrap/seed/compiler.wasm`
  そのもの (seed.json で sha256 pin)。
- `vibe-compiler-module-source-<tag>.vibe` — flatten 済みの flat module source。
  `emit-module-source` の出力 (= committed compiler source からの決定的関数) を
  pin したもの。これがあれば flatten を再実行せず prebuilt をそのまま使える
  (regeneration は seed-based の `scripts/generate_bundle.sh`)。
- `vibe-compiler-seed-<tag>.json` / `release-manifest.json` / `SHA256SUMS.txt` —
  provenance と整合性メタデータ。manifest の `compiler` block に各 asset の
  sha256 と `source_commit` が入る。

取得は共通で `scripts/fetch_compiler.sh` (`pkf run fetch-compiler`)。

```bash
# release から pull + sha256 検証し、prebuilt module source の env を出す
eval "$(pkf run fetch-compiler -- <tag> --print-env)"
# flat source の regeneration を skip して stage0 -> stage1 -> stage2 を回す
bash scripts/generations.sh build
```

`scripts/generations.sh` の `prepare_flat_cli_source` は
`VIBE_PREBUILT_MODULE_SOURCE`(+ optional `..._SHA256`)が指定されると
regeneration を skip して pull 済み flat source を使う。未指定時は
`scripts/generate_bundle.sh` (seed compiler ベース) で regenerate する。

freshness 契約: prebuilt flat source は **対応する source commit / tag 専用**。
HEAD 開発で compiler source を変えた場合は stale になるため、その場合は
`scripts/generate_bundle.sh` で regenerate する。stale な artifact を使うと
flat source が現在の source と食い違い、stage1/stage2 parity 失敗として
顕在化する (fetch 側は manifest の `source_commit` を、`--adopt-seed` 時は
`seed.json` の sha256 を突き合わせて誤用を弾く)。

### 生成物のマージコンフリクト

`lib/@vibe/compiler/` には `scripts/generate_bundle.sh` の出力が5つ commit
されている (seed だけで build できる bootstrap 契約のため):

```
compiler_sources_bundle.vibe
cli_adapter_bundle.vibe
selfbuild_runtime_entry_bundle.vibe
_cli_adapter_module_source.vibe
cache/codegen_fingerprint.vibe
```

5つとも (pinned seed, compiler source) の決定的な関数で、**git 管理下に無い**。
必要なときに `scripts/ensure_generated.sh` が作る。

```bash
bash scripts/ensure_generated.sh                      # stale なら再生成、でなければ ~1s の no-op
bash scripts/ensure_generated.sh --check              # 生成せず鮮度判定のみ (stale なら exit 1)
bash scripts/ensure_generated.sh --print-fingerprint  # CI の cache key 用
```

鮮度は fingerprint = sha256(seed wasm + manifest + 全ライブラリ `.vibe`) で
判定し、`lib/@vibe/compiler/.generated.stamp` に記録する。生成前に stamp を
消すので、中断した実行が「半端な成果物を current と称する」ことはない。

**bootstrap の循環は無い。** かつて flatten ツールは commit 済みの
`_cli_adapter_module_source.vibe` を seed でコンパイルして作っていた
(だから成果物自身が入力になっていた) が、pinned seed は live tree の import を
自分で解決して merged program を印字できる (`VIBE_EMIT_MERGED_SOURCE`)。
今は seed の3パス (flatten → emit-module-source → compile) でツールを立ち上げ、
そのツール = **現在の source の merge 機構**で最終的な flatten を行う。seed の
flatten を最終出力に使わないのは、それが一世代古く、`merge_sources.vibe` 等を
編集しても次の seed bump まで反映されない (しかも出力は妥当なままなので気づけ
ない) から。この切り替え時に、seed だけから作った5成果物が従来の commit 済み
コピーと **byte-identical** であることを確認している。

`coverage_drivers.sh` の #1633 exact-path exposure も同じ世代境界を守る。
新しい内部 mode は current source から作る `compiler_cov.wasm` が実行し、driver
entry から DCE した通常の vibe source を出力する。固定 seed が担当するのはその
出力の coverage compile だけであり、新しい mode を seed 自身が理解する必要は
ない。このため syntax 追加も seed bump も伴わず、通常の
`VIBE_EMIT_MERGED_SOURCE` 出力も変更しない。

### なぜ tracking をやめたか

- compiler source に触る PR が2本あれば**必ず**5ファイル全部で衝突し、
  しかも正しい内容はどちらの側でもなく merge 後の source から regenerate した
  ものだけだった。専用の後始末スクリプト (`resolve_generated_conflicts.sh`) が
  必要で、複数 commit の rebase では tip でもう一度回す必要があり、#1276 は
  それを飛ばして CI を落とした。
- packfile の約30% (1.6GB 中 476MB) がこの履歴だった (直近200 commit 中159)。
- 「commit 済みコピーを黙って優先する」経路があり、regenerate を忘れた source
  編集が**その編集を含まないコンパイラ**を生んでも成功と報告された。
- CI はどのみち生成していた — commit 済みコピーと一致することを確認するためだけに
  (`check_module_source_sync.sh`)。比較をやめて生成するだけにすれば、同じ仕事から
  この失敗モードが消える。

commit され続けるのは `bootstrap/seed/compiler.wasm` だけ (これも実体は
`bootstrap/seed.json` の pin から `ensure_seed.sh` が取得する)。これは還元
不可能 — チェーン全体の出発点となる不動点そのもの。


`.gitattributes` はこの5ファイルを `-diff linguist-generated` にしている。
13MB の1行 bundle が diff に出ないようにするためと、衝突したときに
何千個もの conflict marker ではなく whole-file conflict にするため。

### printer の出力を変えても bootstrap bump は要らない (#1429 step 3)

`lib/@vibe/parser/printer.vibe` の出力を変えると生成物 (flatten は宣言を
`print_program` 経由で書く) の中身も変わるが、それは **bump の理由にならない**。
bump が要るのは compiler source 自体が **seed の読めない新しい syntax** を
使い始めるときだけで、printer が何を*出す*かは seed が何を*読める*かと独立。

#1429 step 3 (effect row を braceless 化) では、committed seed
(`effect-row-spellings-2026-08-04`) に `with A + B` / `with ()` を直接食わせて
parse できることを確認した上で、bump なしで通している。**推論ではなく probe
すること** — seed が読めるかどうかは1コマンドで確かめられる。

> **履歴**: #1443 以前、この変更は `generate_bundle.sh` を**収束するまで複数回**
> 回す必要があった (printer 実測で3パス)。`_cli_adapter_module_source.vibe` が
> 1世代前のスナップショットでありながら次の flatten の入力でもあったため、
> printer の変更が1 pass につき1世代しか進まなかった。#1443 が seed に live
> tree を直接解決させ (`VIBE_EMIT_MERGED_SOURCE`)、成果物の tracking もやめた
> ので、この世代遅れも `drift detected` ゲートも今は存在しない。

### bootstrap bump の手順 (更新版)

`seed-release.yml` は **tag push ではなく `workflow_dispatch`** で手動起動する
— tag を push した時点の commit の `bootstrap/seed.json` はすでに「新しい」
seed を指しているため (`adopt` がそう書き換える)、tag push を trigger に
すると CI がその新しい seed 自身の (まだ存在しない) release から stage0 を
fetch しようとする自己参照になってしまう。`workflow_dispatch` の
`prior_seed_ref` 入力で「どの既存 (公開済み) seed を stage0 として使うか」を
明示することでこれを避ける。

1. `scripts/generations.sh build --stage3` で stage2 candidate を作り、
   gate (上記) を通す。
2. `scripts/generations.sh adopt --artifact <stage2.wasm> --name <name> \
   --tag seed/<name> --source-commit <commit>` — `bootstrap/seed.json` を
   更新 (artifact は `bootstrap/seed/compiler.wasm` へコピー、sha256/tag を
   記録)。**`--tag` には必ず `seed/` prefix を付ける**。
3. `bootstrap/seed.json` の更新を独立 commit にして PR、merge。
4. merge 後、GitHub Actions の `seed-release` workflow を `workflow_dispatch`
   で手動起動する。入力:
   - `tag`: ステップ2で指定した `seed/<name>`。
   - `source_ref`: merge commit (省略時はデフォルトブランチの HEAD)。
   - `prior_seed_ref`: **必須**。`source_ref` 自身の `bootstrap/seed.json`
     は (adopt がそう書き換えるので) 常にこれから publish しようとしている
     「新しい」seed 自身を指しており、stage0 として使えない — 省略可能な
     self-reference は存在しない。2 通りのケースがある:
     - **#1000 part 2 の移行時点の最初の release**: `bootstrap/seed/compiler.wasm`
       (または旧名 `selfhost_compiler.wasm`) がまだ git-tracked だった
       commit (この移行 PR より前の main の任意の commit) を指す。CI は
       その commit から artifact を `git show` で直接取り出す (release 不要)。
     - **それ以降の通常の bump**: source を実際に変える前、直近の
       `seed/*` release がまだ有効だった commit を指す。CI はその commit の
       `bootstrap/seed.json` を一時的に読み込み、そこに pin された release
       から `scripts/ensure_seed.sh` で fetch する。
   - CI はどちらのケースかを自動判定 (`prior_seed_ref` で対象パスが
     git-tracked かどうかを試す) し、prior artifact を確保 →
     `scripts/generations.sh build --stage3` で決定論的に再構築 →
     `scripts/generations.sh adopt` でこのワークスペース限定 (uncommitted)
     に artifact を確定 → asset を publish。
5. 公開された release は **prerelease** として Releases 一覧に載る。以降、
   `bootstrap/seed.json` の pin を見た全ての CI/ローカル環境が
   `scripts/ensure_seed.sh` 経由でこの release から自動的に fetch する。
   (この repo は GitHub の "immutable releases" 設定が有効なため、
   release は一旦 `draft: true` で作成して asset を添付し、その直後の
   別ステップで `gh release edit --draft=false` により publish する
   — `prerelease: true` だけだと asset upload 前に `release.published`
   が発火し、asset 添付が `immutable release` エラーで失敗するため。
   同じ tag への再 dispatch は、その tag の release が既に publish 済み
   なら (immutable のため二度と draft に戻せない) ワークフロー冒頭の
   preflight で早期に fail する — 対処は `gh release delete <tag> --yes
   --cleanup-tag` で削除してから再実行するか、別の tag を使うこと。)

### 既存の git 履歴中のバイナリ blob

この移行以前に git commit で積まれた seed バイナリの履歴 (~20 commit) は
そのまま残す — history rewrite は既存の clone/fork/開いている PR を壊す
破壊的操作であり、この移行の範囲外。新規のバイナリ commit が増えなくなる
だけでも `.git` の肥大化は止まる。将来的に history を圧縮したくなったら、
それは完全に別の、事前合意の上での単発メンテナンス作業として扱う。

## Layer split

cutover 後も runner と compiler artifact は分ける。

- runner layer: `runtime/viberun`、wasmtime flags、cwasm cache、
  host import、component adapter。
- compiler wasm layer: `lib/@vibe/cli/` の CLI entry と `lib/@vibe/compiler/` の compiler 実装から作る dist/component/check entry。

runner layer は性能・実行基盤の都合で差し替えてよいが、canonical compiler は
portable な compiler wasm として再構築できることを gate に残す。

## Compiler wasm artifact 層の contract

compiler wasm を作る canonical な入口は 1 つ:

| artifact | builder | 出力先 | 役割 |
|---|---|---|---|
| stage2 | `scripts/generations.sh build` | `_build/selfhost/generations/<ts>/stage2.wasm` | pinned seed から self-reproduce した candidate。bootstrap bump / release の元。 |

配布物 (release asset の `vibe-compiler-<tag>.wasm`) は adopt された seed
(= 過去の stage2) そのもので、`scripts/build_release_assets.sh` /
`scripts/build_seed_release_assets.sh` が publish する。

`scripts/generations.sh status` で seed pin / source commit / 直近
generation manifest (stage0..stage3 の sha, stage3==stage2) を rebuild 無しで
確認できる。stage0 → stage1 → stage2 → bump の追跡入口。

> **Historical (#529, MoonBit host 時代):** かつては MoonBit host-compiled の
> `dist` artifact (`scripts/build_selfhost_dist.sh` →
> `_build/dist/selfhost_compiler.wasm`) が第2の入口として存在し、dist / stage2
> の等価性を `scripts/test_dist_stage2_parity.sh`
> (`pkf run test-dist-stage2-parity`) の parity gate (ABI 一致 + behavioural
> parity + byte 一致) で保証していた。MoonBit host 退役 (#594) で dist builder は
> 撤去され、この parity gate は gate 本流から外れた。dist builder を失って
> dead になっていた script / task 本体も #1271 の cleanup で撤去済み
> (`vibe.abi` の検証自体は `scripts/generations.sh` / `test_host_abi.js` /
> host runner 側が現役でカバーする)。経緯は
> [docs/archive/moonbit-retirement.md](archive/moonbit-retirement.md)。

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
- `host_import_abi` は runner 層 (`VIBE_IMPORT_ABI`) の host import 選択に
  対応する (現状 `raw`)。runner はこの値で import の解決方法を切り替える。
- どの世代の compiler (seed / stage1 / stage2) で compile しても、**出力
  program wasm の `vibe.abi` は一致しなければならない** (= ABI contract)。
  世代間の挙動一致は stage parity (stage3 == stage2) が保証する。

## MoonBit `src/` の退役 (完了 — historical)

**退役は #594 (2026-06-23) で完了した。** MoonBit host 実装 (`src/`,
`moon.mod`) は全撤去済みで、compiler は committed seed
(`bootstrap/seed/`) + selfhost source (`lib/@vibe/compiler/`,
`lib/@vibe/cli/`) だけからビルド・検証・実行される。MoonBit toolchain
(`moon`) は不要。

- 移行記録: [docs/archive/moonbit-retirement.md](archive/moonbit-retirement.md)
- recovery point (最後の MoonBit-host 状態): tag
  `moonbit-host-final-2026-06-23` (`59ef040`)

bootstrap 復旧で MoonBit host が必要になった場合は、この tag を checkout して
当時の手順 (上記移行記録に記載) に従う。HEAD 上に `src/` を復活させる変更は
行わない。
