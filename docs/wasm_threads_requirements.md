# wasm + threads 要件メモ

更新日: 2026-06-21
現在の repo 既定:

- `wasmtime 45.0.0` (`deps/wasmtime` submodule / `scripts/install_wasmtime_release.sh`)

元の実測対象:

- `wasmtime 41.0.3 (db1c043b5 2026-02-04)` (system)
- `wasmtime 43.0.0 (57b4bf56c 2026-02-06)` (`deps/wasmtime` submodule)

## ⚠️ deprecation: WASI Threads (`-S threads=y`) は通常経路で非推奨 (#486)

`-S threads=y`（= `-Sthreads`、WASI Threads / `wasm32-wasip1-threads`）は
**Wasmtime 47.0.0 (2026-07-20 予定) で hard error になり削除される**。
Wasmtime 45/46 で `-S threads=y` を使うと次の警告が出る:

```text
WARNING: the `-Sthreads` flag will be a hard error in Wasmtime 47.0.0 on 2026-07-20.
```

参考:

- https://github.com/bytecodealliance/wasmtime/releases/tag/v45.0.0
- https://docs.wasmtime.dev/stability-wasm-proposals.html
- https://github.com/WebAssembly/shared-everything-threads

### 方針

- **`-S threads=y`（wasi-threads）を通常経路の推奨から外す。** 本メモの WASI Threads
  手順は historical reference として残し、新規開発では使わない。
- **supported なスレッド面は core wasm の atomics + shared memory** に閉じる
  (`-W threads=y` + `-W shared-memory=y`)。これは廃止対象ではない。下記 §1。
- 公開並行モデルは [ADR-0068](concurrency.md) の shared-nothing structured
  concurrency とする。**shared-everything-threads** はその opt-in 高速化 backend
  として、Wasmtime の不足実装が揃ってから再評価する。tracking: #488。
- repo 内の active な gate (`scripts/test_cli_*preview2*.sh` 等) は
  `VIBE_WASMTIME_WASM_FLAGS=...threads=y`（= `-W threads=y`、wasm proposal）だけを
  使い、廃止対象の `-S threads=y` は使っていない。これらは影響を受けない。

## 1. supported: core wasm atomics + shared memory（非廃止）

`-W threads=y` / `-W shared-memory=y` は wasm threads proposal（atomics + shared
memory）であり、`-S threads`（wasi-threads）とは別物で deprecation の対象外。
atomics / shared memory を使う core wasm の最小要件:

最小 WAT（`memory shared` + `i32.atomic.store/load`）での実測:

- デフォルト:
  - `shared memory support is disabled for this engine -- see Config::shared_memory`
- `-W shared-memory=y`:
  - 成功
- `-W shared-memory=y -W threads=n`:
  - `threads must be enabled for shared memories`

つまり atomics を使う core wasm は少なくとも `-W shared-memory=y` が必要で、
`-W threads=y` も明示するのが安全。

`vibe` の env 変数:

- `VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'`（→ `-W threads=y -W shared-memory=y`）

## 2. historical: WASI Threads (`-S threads=y`) — 非推奨

> ⚠️ 以下は Wasmtime 46 までで動く WASI Threads の手順だが、Wasmtime 47.0.0 で
> `-S threads=y` が削除されるため新規利用は避けること。記録として残す。

Rust なら `wasm32-wasip1-threads` を使う。

```bash
rustup target add wasm32-wasip1-threads
rustup run stable rustc --target wasm32-wasip1-threads -O main.rs -o app.wasm
```

WASI Threads モジュールとして必要な形:

- import:
  - `env::memory` (shared memory import)
  - `wasi::thread-spawn`
- export:
  - `wasi_thread_start`

ホスト側フラグ（Wasmtime 46 まで）:

- WASI: `-S threads=y`  ← **47.0.0 で削除**
- Wasm: `-W shared-memory=y`
- Wasm: `-W threads=y`

失敗パターン（実測）:

- `-S threads=y` なし: `unknown import: env::memory has not been defined`
- `-W shared-memory=y` なし: `shared memory support is disabled for this engine`
- `-W threads=n` で shared memory モジュールを読む: `threads must be enabled for shared memories`

## 3. concurrency-support との関係

- core wasm threads / WASI threads 実行には不要。
- ただし Component Model の `component-model-async` / `component-model-threading` では別扱い。
  - 43 系の実測では `concurrency-support=y` が必要。
  - 41 系は `-W concurrency-support=...` 自体が未対応（unknown option）。

## 4. 実験 backend: shared-everything-threads (#488)

`-S threads`（wasi-threads）は core wasm の上に WASI 層で thread-spawn を載せる
旧アプローチ。Wasm 側の後継候補は **shared-everything-threads** proposal
（`thread.spawn-ref` / `thread.spawn-indirect` / `thread.available-parallelism`
等）だが、これは vibe の公開 API ではない。Wasmtime 側の実装が揃ってから
ADR-0068 の task/channel semantics を保つ lowering として probe を組み直す。

#488 の現状では local patch 上の shared `i31` subset と既存 Component Model
threading baseline は確認できる一方、上記 3 intrinsic は unsupported path に入り、
proposal test と parser/runtime の名前にも差がある。通常 CI / release gate にはせず、
feature detection 付きの opt-in probe に限定する。production 候補への昇格条件は
[concurrency.md の #488 節](concurrency.md)を参照。

- proposal: https://github.com/WebAssembly/shared-everything-threads
- tracking issue: #488

旧 probe (`src/x/threads/`, `just experimental_wasi_threads_probe`,
`scripts/run_wasi_threads_probe.sh`) は既に repo から撤去済み。再導入する場合は
wasi-threads ではなく、backend-neutral conformance test と分離した
shared-everything opt-in probe とする。
