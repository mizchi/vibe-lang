# Compiler Operation Gate

Status: accepted from 2026-06-12.

この文書は、vibe compiler を運用するための gate と判断基準を固定する。
長期方針と bootstrap bump の詳細は [bootstrap.md](bootstrap.md) に従う。

## Cutover Baseline

採用した基準:

- source commit: `39eab0519952ca72599b0b7064d00e3fbd2ac302`
- seed tag: `selfhost-cutover-base-2026-06-12`
- seed artifact: `bootstrap/seed/compiler.wasm`
- seed sha256: `f9da8e285fe0c71c33670a2b9a13a49088dee3ec9a46d2175e975968c6b4b26b`
- source of truth: `lib/@vibe/compiler/` and `lib/@vibe/cli/`
- MoonBit `src/`: (cutover 当時) legacy bootstrap / fallback / host-runner 層。
  その後 #594 (2026-06-23) で撤去済み — recovery point は tag
  `moonbit-host-final-2026-06-23` (`59ef040`)

2026-06-12 の local cutover sign-off:

| gate | value |
| --- | ---: |
| stage0 -> stage1 -> stage2 -> stage3 | green |
| stage2 == stage3 | true |
| generation peak wasm memory | 843 pages / 55,246,848 bytes |
| TOTAL compile ratio | 1.143x |
| TOTAL check ratio | 0.116x |
| compile peak RSS ratio | 1.402x |
| check peak RSS ratio | 0.920x |
| corpus REAL gaps | 0 |
| full-gate | green |

## Development Mode

compiler/checker/codegen の挙動変更は `lib/@vibe/compiler/` に入れる。CLI の
コマンド挙動、adapter、bundle、component entry は `lib/@vibe/cli/` と
`lib/@vibe/compiler/` 側を source of truth とする。旧 MoonBit `src/` は #594 で
撤去済みで、現在の bootstrap 境界は committed seed (`bootstrap/seed/`) のみ。

通常の feature / bugfix は次の順で進める。

1. `lib/@vibe/compiler/` 側に test を追加して Red を確認する。
2. `lib/@vibe/compiler/` または `lib/@vibe/cli/` の実装を直して Green にする。
3. 必要なら `scripts/generate_bundle.sh` で bundle を同期する。
4. `pkf run full-gate` を通す。
5. 互換や配布 artifact に影響する変更だけ `pkf run release-check` も通す。

コンパイラが自分をコンパイルできない等 bootstrap 側の問題に見える場合は、
原因を `lib/@vibe/compiler/` / `lib/@vibe/cli/` / bootstrap scripts / seed 管理へ
切り分ける。旧 MoonBit host (`src/`) はもう存在しないため、break-glass 先は
tag `moonbit-host-final-2026-06-23` の checkout になる — 使う場合は通常
feature commit とは分け、明示的な方針確認を行う。

bootstrap bump は通常の feature commit と分ける。新 syntax を compiler source
自身で使い始める場合は、先にその syntax を理解する seed を作ってから source を
移行する。

### Perceus / RC codegen

`pkf run test` (`compiler_gate.sh`) is the pre-commit main check, but it is
not the full RC net. Step 40d measures leaks; steps 40f / 40f2 run
`VIBE_RC=shadow` on the #715 shape corpus and three checked-artifact tests.
A dup/drop *under*-provision (the first cut of #1964) still reproduced the
compiler byte-identically and stayed green on those steps — only
`scripts/unit_test_runner.sh` trapped, when compiled tests ran
`check_program` over nontrivial input.

Changes under `lib/@vibe/compiler/perceus/` or RC-relevant codegen require
a full `scripts/unit_test_runner.sh` run before push, not just the gate.

## Operation Gate

compiler の継続運用判断には以下を使う。

```bash
pkf run full-gate
```

旧 `pkf run selfhost-trial-gate` 互換 alias は #850 Phase B で削除した
(生存中の呼び出し元がなかったため)。

この task は次をまとめて確認する。

- `generation-gate`: fixed seed -> stage1 -> stage2 -> stage3
- `post-generation-gate` (`scripts/gate.sh --post-generation` -> `trial_gate.sh`):
  sign-off一式

旧 host 比較系 (`test-selfhost-corpus-gate` / `perf-kpi` / `rss-kpi` /
component parity) は MoonBit host 退役 (#594) でスクリプトごと退役済み。
対応する task は Taskfile から削除した (dead-task cleanup)。

stage generation は gate の先頭で固定している。post-generation 系を先に実行したあとに generation を走らせると、host runner
側の Node/Wasm 実行が segfault することがあるため、Taskfile では
`generation-gate` -> `post-generation-gate` の依存チェーンにしている。

短い調査ループでは、必要な部分だけを単独で走らせてよい。

```bash
pkf run release-gates   # = scripts/compiler_gate.sh
pkf run generation-gate
```

### Fixture は列挙しない — glob で拾う (#1587)

テストブロックを持つ fixture の実行は**手書きの列挙で管理しない**。
`compiler_gate.sh` にはかつて同じループの写しが 3 箇所あり、それぞれが
`for fx in \` + バックスラッシュ継続のリストを持っていた。この形は 2 つの
壊れ方をする。

1. fixture を足す PR が**必ずリスト末尾の同じ行を取り合う**
2. fixture をコミットして gate への追記を忘れると、**どこでも実行されない
   まま「カバレッジがあるように見える」** ——「黙って誤る」の隣接系

今は `run_test_block_fixtures <label> <glob>` に一本化してあり、呼び出し側は
必ず glob を渡す (`fixtures/derive_*_test.vibe` など)。規約に乗った fixture は
置いた瞬間から走る。glob が 1 件も match しなければ gate は落ちる (無言で
0 件を回すのが最悪なので)。

3 つ目の状態 —— どの lane にも拾われない fixture —— は
`scripts/check_fixture_execution.sh` が塞ぐ。`fixtures/**/*.vibe` のうち
`test` ブロックを持つものは、次のいずれかでなければならない:

- `scripts/unit_test_runner.sh --list` に載る (= `*_test.vibe` 命名規約。
  **これが最も安い**)
- `fixtures/typecheck/expected.tsv` に verdict 行がある (この lane は行ごとに
  期待判定を持つので glob では代替できない。代わりに**網羅性**を検査する)
- `scripts/` / `lib/` / `examples/` / `.github/` のどこかが名前で参照している
  (= 個別の期待値を持つ bespoke check)
- `scripts/fixture_execution_exceptions.txt` に**理由付きで**載っている

どれでもなければ gate が落ち、直し方 4 択を出す。純 shell で ~2s なので
`compiler_gate.sh` の**先頭**、selfbuild の前で走る。単独では
`pkf run check-fixture-execution`。

> この検査を入れた時点で 10 件が「どの lane にも拾われない」状態だった
> (#641 Phase 1 の受け入れ fixture 1 件と、`fixtures/runtime/` の struct
> fixture 9 件)。後者は `__DATA__` マーカーの**後ろ**に test ブロックが
> 置かれていて、ソースとしてすら成立していなかった
> (`line 13:1: top-level expressions are not allowed`)。いずれも
> `*_test.vibe` へ改名して unit lane に載せてある。

## Cold FS Compile Memory Observation (#1553)

The full CLI's FS compile can approach wasm32 linear-memory limits only on a
cold persistent-cache run. Measure it separately from the normal operation
loop; each invocation uses a unique temporary run directory for its compiler
cache, output, and logs, and prints deterministic guest `pages` and `heap_ptr`
values (RSS is diagnostic only). `--warm` snapshots its persistent cache into
that isolated run directory and serializes snapshot updates with a lock. Set
`VIBE_FS_HEAP_KEEP_RUN_DIR=1` to retain a run's diagnostics; cold runs can
optionally use `VIBE_FS_HEAP_LOCK_DIR=/path/to/lock` for host-resource
exclusion:

```bash
pkf run measure-fs-heap -- --cold --base path/to/stage2.wasm
# Optional 3.5 GiB (= 57344 wasm pages) failure threshold:
pkf run measure-fs-heap -- --cold --gate --base path/to/stage2.wasm
# Optional byte parity check, at the cost of a second cold compile:
pkf run measure-fs-heap -- --cold --verify-parity --base path/to/stage2.wasm
```

The real measurement is deliberately opt-in rather than an always-on CI lane:
a cold whole-CLI run is materially more expensive than the existing
single-input `selfcompile-kpi` gate. The normal `compiler-gate` does run the
cheap fake-runner protocol self-test, which verifies environment sanitization,
per-run cache isolation, cleanup, locking, and fail-closed parsing without
performing a full-CLI compile. Promote the real `--cold --gate` invocation only
after recording repeated cold-run duration/resource data and a reviewed
threshold rationale. At that point, add it to the existing `compiler-gate` CI
job using that job's already-built stage2 artifact; do not add a second stage
build solely for this measurement. The mark labels are observable call
boundaries, not claims about separately unobservable normalize or link work.

## Stop Criteria

次のどれかが起きたら、compiler の運用は一時停止して原因を切り分ける。

- fixed seed から stage2 が再現できない。
- corpus REAL gap が増える。
- TOTAL compile > 2.5x、TOTAL check > 1.33x、peak RSS > 2.0x が再現する。
- runner 層の wasmtime/cwasm 依存が portable wasm correctness と乖離する。
- 新機能または CLI 変更の実装が selfhost source (`lib/@vibe/compiler/` /
  `lib/@vibe/cli/`) だけで完結できず、退役済み MoonBit host の復活が必要になる。
