# wasmtime v43 周辺メモ

更新日: 2026-02-09

このドキュメントは、`wasmtime` の `v41.0.3` (stable) と `origin/main` (43 系開発中) を比較しつつ、
「Wasm runtime + WASIp3 ホストを内蔵したライブラリ」を作るときの実装メモをまとめたもの。

## TL;DR

- `v41.0.3` でも `component-model-async` と `component-model-async-bytes` は利用可能。
- `v41.0.3` には `Config::concurrency_support(...)` はまだ無い。
- `origin/main` (43 系) では `Config::concurrency_support(...)` が追加され、CM async 周りの制御が明示的。
- WASIp3 は `p3` という git ブランチ名ではなく、`wasmtime_wasi::p3` として開発されている。
- `deps/wasmtime` (main, `57b4bf56c`) の CLI では `-W component-model-async*` と `-W concurrency-support` が有効。
- `component-model-async-bytes` は runtime の `-W` フラグではなく compile-time feature（`-W component-model-async-bytes` は unknown）。
- `-W component-model-async=y,concurrency-support=n` は設定衝突で失敗する。
- この環境では `-W stack-switching=y` は compiler configuration 非対応で失敗する。

## 1. 41 系で使えるもの

`wasmtime = 41.0.3` で以下は有効化できる。

- Cargo feature
  - `component-model`
  - `component-model-async`
  - `component-model-async-bytes`
  - `async`
- Runtime config
  - `config.wasm_component_model(true)`
  - `config.wasm_component_model_async(true)`

`cargo check` による最小確認済み。

## 2. 自作ライブラリに必要な最小構成

### 2.1 依存関係 (stable 41 系)

```toml
[dependencies]
wasmtime = { version = "41.0.3", default-features = false, features = [
  "runtime",
  "std",
  "cranelift",
  "component-model",
  "component-model-async",
  "component-model-async-bytes",
  "async",
] }
wasmtime-wasi = { version = "41.0.3", default-features = false, features = ["p3"] }
wasmtime-wasi-http = { version = "41.0.3", default-features = false, features = ["p3", "default-send-request"] }
tokio = { version = "1", features = ["rt-multi-thread", "macros", "time", "net", "sync", "io-util"] }
```

### 2.2 Host state

- 必須
  - `WasiCtx`
  - `ResourceTable`
  - `WasiView` 実装
- HTTP も使う場合
  - `DefaultWasiHttpCtx`
  - `WasiHttpView` 実装

### 2.3 Linker 登録

```rust
wasmtime_wasi::p3::add_to_linker(&mut linker)?;
wasmtime_wasi_http::p3::add_to_linker(&mut linker)?; // HTTP が必要な場合
```

### 2.4 実行モデル

WASIp3/CM async を使う場合は、以下が基本。

- `Store::run_concurrent(...)`
- `component::Func::call_concurrent(...)`
- `wasmtime_wasi::p3::bindings::Command` の `call_run(...)`

`call_concurrent` で開始した処理は `run_concurrent` の駆動がないと進まない。

## 3. async 系で有効化できるもの

### 3.1 コンパイル時 (Cargo feature)

- `async`
- `component-model`
- `component-model-async`
- `component-model-async-bytes`

### 3.2 Runtime config (`Config`)

CM async 関連:

- `wasm_component_model_async`
- `wasm_component_model_async_builtins`
- `wasm_component_model_async_stackful`
- `wasm_component_model_threading`
- `wasm_component_model_error_context`
- `wasm_component_model_fixed_length_lists`

旧 async/fiber 系:

- `async_stack_size`
- `async_stack_zeroing`
- `async_stack_keep_resident`

実行制御:

- `consume_fuel` + `Store::fuel_async_yield_interval`
- `epoch_interruption` + `Store::epoch_deadline_async_yield_and_update`

## 4. 41 系と 43 系 (main) の主な差分

### 4.1 `concurrency_support`

- 41 系: `Config::concurrency_support` は存在しない
- 43 系 (main): `Config::concurrency_support(bool)` が利用可能

`main` では、CM async 系 feature (`CM_ASYNC`, `CM_THREADING`, `CM_ERROR_CONTEXT` など) と
`concurrency_support` の整合性チェックが `Config` 検証時に行われる。

### 4.2 `async_support`

- `Config::async_support(...)` は実質 no-op (非推奨)。
- 新しいコードでは依存しない方がよい。

### 4.3 post-return

- main 側では `post_return[_async]` が no-op 扱いに移行。
- 呼び出しコード側で明示 `post_return_async` を書かない実装へ整理されつつある。

## 5. 41 系向け最小コード

```rust
use wasmtime::{Config, Engine, Store};
use wasmtime::component::{Linker, ResourceTable};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};
use wasmtime_wasi_http::p3::{DefaultWasiHttpCtx, WasiHttpCtxView, WasiHttpView};

struct HostState {
    wasi: WasiCtx,
    http: DefaultWasiHttpCtx,
    table: ResourceTable,
}

impl WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl WasiHttpView for HostState {
    fn http(&mut self) -> WasiHttpCtxView<'_> {
        WasiHttpCtxView { ctx: &mut self.http, table: &mut self.table }
    }
}

#[tokio::main]
async fn main() -> wasmtime::Result<()> {
    let mut config = Config::new();
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);

    let engine = Engine::new(&config)?;
    let mut linker = Linker::<HostState>::new(&engine);
    wasmtime_wasi::p3::add_to_linker(&mut linker)?;
    wasmtime_wasi_http::p3::add_to_linker(&mut linker)?;

    let mut b = WasiCtxBuilder::new();
    b.inherit_stdio();
    let _store = Store::new(&engine, HostState {
        wasi: b.build(),
        http: DefaultWasiHttpCtx::default(),
        table: ResourceTable::new(),
    });

    Ok(())
}
```

## 6. 既知の注意点

- `wasmtime-wasi::p3` と `wasmtime-wasi-http::p3` は「experimental / unstable / incomplete」。
- p3 固有の修正は patch release で必ずしも面倒を見ない方針が明記されている。
- 本番用途では `main` 追従コストを見込んでラッパー層を薄く保つ方がよい。

## 7. 参照

- `crates/wasmtime/Cargo.toml`
- `crates/wasmtime/src/config.rs`
- `crates/wasmtime/src/runtime/component/*`
- `crates/wasi/src/lib.rs`
- `crates/wasi/src/p3/mod.rs`
- `crates/wasi/src/view.rs`
- `crates/wasi/src/ctx.rs`
- `crates/wasi-http/src/lib.rs`
- `crates/wasi-http/src/p3/mod.rs`
- commit `cc8d04f45` (async_support no-op / concurrency 周辺整理)
- commit `c09aa3807` (post_return no-op 移行)

## 8. vibe での運用メモ

`vibe` 側では `deps/wasmtime` を submodule として保持し、通常はシステム `wasmtime`、
実験時のみ submodule ビルドに切り替える運用にしている。

```bash
# 初期化
just wasmtime-submodule-init

# submodule 版 wasmtime-cli をビルド
just build-wasmtime-submodule

# submodule 版を直接使う
just wasmtime-submodule run --help

# vibe scripts/* が使う wasmtime を submodule 版へ切替
VIBE_USE_WASMTIME_SUBMODULE=1 just component-run vibe/std/test_import.vibe
```

## 9. `deps/wasmtime` 実測メモ (2026-02-09)

検証対象:

- `deps/wasmtime/target/release/wasmtime --version`
  - `wasmtime 43.0.0 (57b4bf56c 2026-02-06)`

### 9.1 Runtime (`-W`) で有効化できるもの

`wasmtime run -W help` で以下を確認できる:

- `component-model-async`
- `component-model-async-builtins`
- `component-model-async-stackful`
- `component-model-threading`
- `component-model-error-context`
- `component-model-fixed-length-lists`
- `concurrency-support`

最小 wasm / component 実行では、上記フラグは有効化して実行可能だった。

### 9.2 実測で確認した制約

- `-W component-model-async=y,concurrency-support=n`
  - `Error: concurrency support must be enabled to use the component model async or threading features`
- `-W component-model-threading=y,concurrency-support=n`
  - 上と同様に失敗
- `-W component-model-error-context=y,concurrency-support=n`
  - 上と同様に失敗
- `-W component-model-fixed-length-lists=y,concurrency-support=n`
  - これは実行可能
- `-W stack-switching=y`
  - `Error: the wasm_stack_switching feature is not supported on this compiler configuration`

### 9.3 `component-model-async-bytes` の扱い

- `component-model-async-bytes` は `wasmtime` crate 側の compile-time feature。
- `wasmtime-wasi` の `p3` feature は `wasmtime/component-model-async` と
  `wasmtime/component-model-async-bytes` を有効化する。
- そのため CLI runtime flag (`-W`) に `component-model-async-bytes` は存在しない。

## 10. p3 の runtime 挙動メモ

- `-S help` には `p3[=y|n]` が存在する。
- ただし CLI 側の `P3_DEFAULT` は現在 `false` (`src/common.rs`)。
- `-S p3=y` かつ compile-time で `component-model-async` が有効、かつ component が `wasi:cli`/p3 command を持つ場合に、
  `run` コマンドは `wasmtime_wasi::p3::bindings::Command` 経由の実行パスを選ぶ (`src/commands/run.rs`)。

## 11. vibe との接続点（現状）

- バイナリ切替は `scripts/wasmtime_bin.sh` と `VIBE_USE_WASMTIME_SUBMODULE=1` で統一済み。
- `scripts/wasmtime_run.sh` 経由で `VIBE_WASMTIME_WASM_FLAGS` / `VIBE_WASMTIME_WASI_FLAGS` を注入できる。
- 2 つの環境変数は空白区切りで複数指定でき、各トークンが `-W` / `-S` として渡される。
- `justfile` 側でも `vibe_wasmtime_wasm_flags` / `vibe_wasmtime_wasi_flags` として env を取り込み、
  `component-run` / `bench-*` / `test-component-e2e` / `test-interpreter-wasm` などのタスクへ伝搬される。
- 現在値は `just show-wasmtime-flags` で確認できる。

例:

```bash
VIBE_WASMTIME_WASM_FLAGS='component-model-async=y concurrency-support=y' \
VIBE_WASMTIME_WASI_FLAGS='p3=y' \
VIBE_USE_WASMTIME_SUBMODULE=1 \
just component-run script.vibe
```

## 12. wasi threads / atomics / concurrent 実測 (2026-02-09)

検証環境:

- system: `wasmtime 41.0.3 (db1c043b5 2026-02-04)`
- submodule: `wasmtime 43.0.0 (57b4bf56c 2026-02-06)`

### 12.1 core wasm の atomics + shared memory

最小 WAT（`memory shared` + `i32.atomic.store/load`）で確認。

- デフォルト:
  - 41/43 ともに失敗
  - `shared memory support is disabled for this engine -- see Config::shared_memory`
- `-W shared-memory=y`:
  - 41/43 ともに成功
- `-W shared-memory=y -W threads=n`:
  - 41/43 ともに parse error
  - `threads must be enabled for shared memories`

結論:

- `atomics` を使う core wasm は、少なくとも `-W shared-memory=y` が必要。
- `threads=n` を明示すると shared memory モジュールはロード不能。

### 12.2 WASI Threads（`wasm32-wasip1-threads`）

`rustup run stable rustc --target wasm32-wasip1-threads` で
`std::thread::spawn` を使う最小プログラムを作成して確認。

このモジュールは import に以下を持つ:

- `env::memory` (shared memory import)
- `wasi::thread-spawn`

実行結果:

- `-S threads=y -W threads=y -W shared-memory=y`:
  - 41/43 ともに成功 (`sum=21`)
- `-S threads=y` のみ:
  - 失敗 (`shared memory support is disabled`)
- `-W threads=y -W shared-memory=y` のみ:
  - 失敗 (`unknown import: env::memory`)

結論:

- WASI Threads モジュールの実行には `-S threads=y` と `-W shared-memory=y` が必須。
- 実運用では明示的に `-W threads=y` も付けるのが安全。

### 12.3 並列実行が実際に効いているか

`sleep(500ms)` を 4 回行う比較:

- 直列版（`wasm32-wasip1`）: `real 2.03s`
- スレッド版（`wasm32-wasip1-threads` + `-S threads=y -W threads=y -W shared-memory=y`）: `real 0.51s`

この差分から、少なくとも sleep 待機は guest thread で並列に進行していることが確認できる。

### 12.4 `concurrency-support` との関係

- core wasm atomics / WASI Threads 実行は `-W concurrency-support` に依存しない。
  - 43 で `concurrency-support=n` でも上記ケースは動作。
- `component-model-async` / `component-model-threading` を有効化する場合は別。
  - 43 で `-W component-model-threading=y -W component-model-async=y -W concurrency-support=n`
    は `concurrency support must be enabled ...` で失敗。
- 41 では `-W concurrency-support=...` 自体が unknown option。

### 12.5 vibe リポジトリ内の最小プローブ

この検証を再実行できるように、以下を追加した:

- `src/x/threads/wasi_threads_probe.wat`
- `src/x/threads/run_probe.sh`
- `scripts/run_wasi_threads_probe.sh`
- `just experimental_wasi_threads_probe`

実行例:

```bash
VIBE_USE_WASMTIME_SUBMODULE=1 just experimental_wasi_threads_probe
```

デフォルト（未指定時）では次のフラグを適用する:

- `VIBE_WASMTIME_WASM_FLAGS='threads=y shared-memory=y'`
- `VIBE_WASMTIME_WASI_FLAGS='threads=y'`
