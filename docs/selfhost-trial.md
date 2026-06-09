# Complete Selfhost Trial

Status: active trial from 2026-06-10.

この文書は、vibe compiler を完全 selfhost 前提でしばらく開発し、継続運用に
耐えるかを判断するための trial 手順を固定する。長期方針と bootstrap bump の
詳細は [selfhost-bootstrap.md](selfhost-bootstrap.md) に従う。

## Trial baseline

開始時点の基準 commit:

- `13e866ff Fix selfhost corpus real gaps`
- seed: `bootstrap/selfhost/seed.json`
- source of truth: `vibe/compiler/`
- MoonBit `src/`: bootstrap / fallback / host-runner 層

開始時点の local gate:

| gate | value |
| --- | ---: |
| TOTAL compile ratio | 1.564x |
| TOTAL check ratio | 0.896x |
| compile peak RSS ratio | 1.397x |
| check peak RSS ratio | 0.933x |
| corpus REAL gaps | 0 |
| cutover parity | 30/30 |
| full tests | 1373/1373 |

2026-06-10 に `pkf run selfhost-trial-gate` で再確認した値:

| gate | value |
| --- | ---: |
| TOTAL compile ratio | 1.205x |
| TOTAL check ratio | 0.843x |
| compile peak RSS ratio | 1.399x |
| check peak RSS ratio | 0.935x |
| corpus REAL gaps | 0 |

## Development mode

trial 中は、compiler/checker/codegen の挙動変更を `vibe/compiler/` に入れる。
MoonBit `src/` は、固定 seed から current selfhost compiler を作るための
bootstrap/fallback 境界、runner、または互換確認が必要な場合だけ変更する。

通常の feature / bugfix は次の順で進める。

1. selfhost 側に test を追加して Red を確認する。
2. `vibe/compiler/` の実装を直して Green にする。
3. 必要なら `scripts/generate_selfhost_bundle.sh` で bundle を同期する。
4. `pkf run selfhost-trial-gate` を通す。
5. 互換や配布 artifact に影響する変更だけ `pkf run release-check` も通す。

bootstrap bump は通常の feature commit と分ける。新 syntax を compiler source
自身で使い始める場合は、先にその syntax を理解する seed を作ってから source を
移行する。

## Trial gate

complete selfhost の継続判断には以下を使う。

```bash
pkf run selfhost-trial-gate
```

この task は次をまとめて確認する。

- `selfhost-trial-generation-gate`: fixed seed -> stage1 -> stage2 -> stage3
- `release-selfhost-gates`: component / direct / command / cutover / golden WAT
- `test-selfhost-corpus-gate`: corpus check parity REAL=0
- `selfhost-trial-perf-kpi`: TOTAL compile <= 2.5x、TOTAL check <= 1.33x
- `selfhost-trial-rss-kpi`: peak RSS compile/check <= 2.0x

stage generation は trial gate の先頭で固定している。release/corpus/perf/RSS を
先に実行したあとに generation を走らせると、host runner 側の Node/Wasm 実行が
segfault することがあるため、Taskfile では
`selfhost-trial-generation-gate` -> `selfhost-trial-post-generation-gate` の
依存チェーンにしている。

短い調査ループでは、必要な部分だけを単独で走らせてよい。

```bash
pkf run release-selfhost-gates
pkf run test-selfhost-corpus-gate
pkf run selfhost-trial-perf-kpi
pkf run selfhost-trial-rss-kpi
```

## Go / no-go criteria

trial を継続してよい条件:

- fixed seed から stage2 が毎回作れる。
- corpus REAL gap が 0 のまま。
- perf/RSS が KPI 内に収まる。
- `release-selfhost-gates` と `release-check` が少なくとも節目 commit で green。
- 通常の compiler 開発で `src/` へ戻らないと直せない問題が連続しない。

次のどれかが起きたら、完全移行は一時停止して原因を切り分ける。

- stage2 が fixed seed から再現できない。
- corpus REAL gap が増える。
- TOTAL compile > 2.5x、TOTAL check > 1.33x、peak RSS > 2.0x が再現する。
- runner 層の wasmtime/cwasm 依存が portable wasm correctness と乖離する。
- 新機能の実装に MoonBit `src/` 先行が必要な状態へ戻る。

trial が数日から数週間 green で回るなら、次の段階で default CLI build/run/check
を selfhost wasm 経路へ向け、MoonBit `src/` の退役範囲を具体化する。
