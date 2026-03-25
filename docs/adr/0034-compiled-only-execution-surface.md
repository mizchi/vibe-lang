# ADR-0034: Compiled-Only Execution Surface

- Date: 2026-03-25
- Status: accepted

## Context

`vibe` には長く interpreter と compiled backend の 2 系統が共存していた。
当初は以下の理由で interpreter に価値があった。

- 短い `run` / `shell` の即時フィードバックが速い
- compiled backend の未対応ケースに対する fallback になる
- WASM 実装との差分を見る reference runtime として使える

しかし、ここ数日の作業で前提が変わった。

- `run/check/test` は localhost session worker を既定利用し、同一 process の DB / cache を再利用できる
- incremental compile は同一 process 内では hot path が `short ~=14ms`, `medium ~=31ms` まで落ち、`emit_us = 0` を達成した
- `vibe shell` / `shell-stdin` / `shell --ai` / `shell --tui` は compiled REPL に切り替わり、interpreter 無効でも実用的な応答性で動く
- `bench` も generated wasm cache を持ち、file-based benchmark は compiled path に揃っている

一方で、interpreter を残すコストは大きい。

- host / selfhost evaluator 実装の保守
- CLI の backend 分岐、fallback、互換 env
- evaluator 専用 test / parity lane

このまま 2 系統を product surface として維持すると、設計もテストも常に二重化される。

## Decision

今後の `vibe` の public execution surface は compiled only とする。

- `vibe run`
- `vibe test`
- `vibe bench`
- `vibe shell`
- `vibe shell-stdin`
- `vibe shell --ai`
- `vibe shell --tui`

これらの導線では interpreter backend を product option として提供しない。

具体的には以下を採る。

- `run/test` の backend 選択 env は廃止し、public execution surface は compiled 固定にする
- `bench` の `--backend interpreter` は廃止する
- `bench` の legacy expr mode (`--expr`, `--case`, `--cases`) は廃止する
- `shell` 系は compiled session backend を canonical path とする
- `eval` command は public CLI から外し、interactive evaluation は compiled shell へ寄せる

interpreter / evaluator 実装はただちに全削除しない。
ただし、以後は internal migration target としてのみ扱い、外向き API / CLI surface には出さない。

削除順は次の通りとする。

1. CLI / docs / env から interpreter の公開面を除去する
2. compiled parity が取れた REPL / bench / test 導線へ移行する
3. `cli_repl_js` を廃止し、runtime evaluator API の残存 caller を整理する
4. host / selfhost の evaluator 実装と専用 test を削除する

この判断により、ADR-0002 の「interpreter を public backend としてサポートする」決定は、
execution surface に関して superseded とする。

## Consequences

良い面:

- `run/test/bench/shell` の product 契約が 1 本化される
- incremental compile と session cache への投資がそのまま mainline UX 改善になる
- CLI help / docs / parity gate が単純になる
- interpreter 専用の保守面積を段階的に削減できる

悪い面:

- legacy expr bench や evaluator 依存ワークフローは破壊的変更になる
- compiled backend の未対応箇所は fallback ではなく明示エラーとして見える
- runtime evaluator を完全削除するまでは、内部実装と外部契約に一時的なズレが残る
