# ADR-0028: Selfhost CLI / I-O Boundary

- Date: 2026-03-10
- Status: accepted

## Context

selfhost compiler は strict-recursive selfbuild と gate 群まで到達し、`vibe/compiler/index.vibe` から compile API と cache helper を export できる状態になった。一方で、selfhost artifact をそのまま「CLI」と呼ぶと、どこまでを selfhost 側の責務にするかが曖昧になりやすい。

特に次の 2 つを分けて扱う必要がある。

- 純粋な compile pipeline
  - source / module map を受けて parse, check, codegen を返す層
- 環境依存の I/O
  - filesystem, environ, stdio, path resolution, output file write, batch orchestration

現状の `vibe_compile_wasi` は wasm target 上で compile command を実行できるが、I/O 自体は host adapter と `src/cmd/*` が担っている。selfhost 側へ WASI import を直接増やすと、pure compile API と packaging/runtime concerns が再び混ざる。

## Decision

selfhost compiler の責務は当面「純粋 compile API」までに固定する。

- selfhost 側に残すもの
  - `compile_source`, `compile_source_wasi`
  - `compile_with_modules*`
  - `compile_file_fs*_cached`
  - `prepare_jobs_cached`, `compile_jobs_cached`
  - selfbuild / cache probe / manifest-driven module loading
- host / adapter 側に残すもの
  - filesystem read/write
  - environ / cwd / include path resolution
  - stdout/stderr rendering
  - CLI option parse
  - release gate orchestration
  - wasm target CLI wrapper (`src/cmd/vibe_compile_wasi`)

将来 selfhost 単体 artifact を standalone CLI として閉じる場合は、pure compile API の上に別レイヤとして WASI Preview 2 / Component Model adapter を追加する。

- core selfhost compiler に FS/environ import を直結しない
- `wasi:filesystem`, `wasi:cli`, `wasi:io/streams` は adapter / wrapper 層で受ける
- selfhost compiler 本体は引き続き source text / module map / output bytes に閉じた API を保つ

## Consequences

- selfhost compiler 本体は host/native/wasm のどの wrapper からも同じ contract で再利用できる
- cache / manifest / selfbuild probe を I/O 実装から独立に進化させられる
- standalone CLI 化には Preview 2 / Component Model adapter の追加実装が別途必要
- `TODO.md` の selfhost CLI 境界は完了扱いにでき、残課題は host loop cache 再利用と component packaging に絞られる
