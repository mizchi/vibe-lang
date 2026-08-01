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

## Stop Criteria

次のどれかが起きたら、compiler の運用は一時停止して原因を切り分ける。

- fixed seed から stage2 が再現できない。
- corpus REAL gap が増える。
- TOTAL compile > 2.5x、TOTAL check > 1.33x、peak RSS > 2.0x が再現する。
- runner 層の wasmtime/cwasm 依存が portable wasm correctness と乖離する。
- 新機能または CLI 変更の実装が selfhost source (`lib/@vibe/compiler/` /
  `lib/@vibe/cli/`) だけで完結できず、退役済み MoonBit host の復活が必要になる。
