# wasm + threads 要件メモ

更新日: 2026-06-02
現在の repo 既定:

- experimental thread probe は project-local prebuilt を使う。
- known-good: `wasmtime 46.0.0 (e6ba8b7d8 2026-06-02)`
- setup: [docs/wasmtime-prebuilt-setup.md](wasmtime-prebuilt-setup.md)

元の実測対象:

- `wasmtime 41.0.3 (db1c043b5 2026-02-04)` (system)
- `wasmtime 43.0.0 (57b4bf56c 2026-02-06)` (`deps/wasmtime` submodule)

## TL;DR

WASI Threads を wasmtime 上で動かす最小要件は次の 3 点:

1. ゲスト wasm が `wasi threads` ABI を満たすこと
2. `-S threads=y` を有効化すること
3. `-W shared-memory=y` と `-W threads=y` を有効化すること

この条件で、実際に並列実行が進むことを確認済み（sleep 4 本で直列約2.03s -> 並列約0.51s）。

## 1. ゲスト側の要件

Rust なら基本的に `wasm32-wasip1-threads` を使う。

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

## 2. ホスト側（wasmtime）の要件

必須フラグ:

- WASI: `-S threads=y`
- Wasm: `-W shared-memory=y`
- Wasm: `-W threads=y`（shared memory 運用で実質必須）

`vibe` の env 変数にすると:

- `VIBE_WASMTIME_WASI_FLAGS='threads=y'`
- `VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'`

## 3. 失敗パターン（実測）

- `-S threads=y` なし:
  - `unknown import: env::memory has not been defined`
- `-W shared-memory=y` なし:
  - `shared memory support is disabled for this engine`
- `-W threads=n` で shared memory モジュールを読む:
  - `threads must be enabled for shared memories`

## 4. concurrency-support との関係

- Core Wasm threads / WASI threads 実行には不要。
- ただし Component Model の `component-model-async` / `component-model-threading` では別扱い。
  - 43 系の実測では `concurrency-support=y` が必要。
  - 41 系は `-W concurrency-support=...` 自体が未対応（unknown option）。

## 5. vibe リポジトリ内での最小実行手順

追加済みプローブ:

- `src/x/threads/wasi_threads_probe.wat`
- `src/x/threads/run_probe.sh`
- `pkf run experimental_wasi_threads_probe`

実行:

```bash
# prebuilt wasmtime を使う
pkf run package-wasmtime-prebuilt
pkf run install-wasmtime-prebuilt
pkf run experimental_wasi_threads_probe

# submodule wasmtime を使う
VIBE_USE_WASMTIME_SUBMODULE=1 pkf run experimental_wasi_threads_probe

# 直接実行
src/x/threads/run_probe.sh
```

## 6. 実装時チェックリスト

- [ ] ゲスト wasm が threads ABI (`env::memory`, `wasi::thread-spawn`, `wasi_thread_start`) を持つ
- [ ] `VIBE_WASMTIME_WASI_FLAGS` に `threads=y` が入っている
- [ ] `VIBE_WASMTIME_WASM_FLAGS` に `threads=y shared-memory=y` が入っている
- [ ] 実行環境の wasmtime バージョンを確認する
- [ ] 必要なら並列実行の実測（時間短縮）で動作を裏取りする
