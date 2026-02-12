# Unstable Feature Flags

更新日: 2026-02-10

## 目的

実験段階の機能を通常実行パスから分離し、既定動作を安定側に固定する。

- 既定: unstable 機能は無効
- 明示 opt-in: CLI フラグでのみ有効

## フラグ

- `--unstable-async`
  - 対象: `sleep(...)`, `await`, `yield` の実行
  - デフォルト: 無効
- `--unstable-threads`
  - 対象: スレッド系 API 拡張
    - `threads_probe_wat()`
    - `threads_runtime_hints()`
  - デフォルト: 無効

配置ルール:

- `vibe --unstable-async run file.vibe`
- `vibe run --unstable-async file.vibe`

の両方を受理する（`--unstable-threads` も同様）。

## 現在の実装状態

### 1. Runtime feature flags 追加

- `RuntimeFeatureFlags` を導入:
  - `stable()`
  - `unstable_async_only()`
  - `unstable_threads_only()`
  - `unstable_all()`
- `Runtime::new_with_features(...)` を追加
- `Runtime::new(...)` は `stable()` を使う既定挙動を維持

### 2. `--unstable-async` の実行ゲート

未有効時は `FeatureDisabled(..., flag="--unstable-async")` を返す。

- `sleep(...)`
- `await expr`
- `yield expr`

### 3. CLI 配線

`src/cmd/vibe`:

- `parse_cli_runtime_args(...)` で以下を受理:
  - `--unstable-async`
  - `--unstable-threads`
  - 既存 `--syntax vibe|posix`
- `run/test/bench/bench-file/repl/repl-stdin/repl-wasi` で
  runtime feature flags を伝播

`src/cmd/vibe_wasi`:

- line REPL オプションとして
  - `--unstable-async`
  - `--unstable-threads`
  を受理し runtime feature flags に反映

### 4. `--unstable-threads` の実行ゲート（現状）

未有効時は `FeatureDisabled(..., flag="--unstable-threads")` を返す。

- `threads_probe_wat()`（WASI Threads probe WAT 文字列を返す）
- `threads_runtime_hints()`（推奨 `-W/-S` と env 文字列を返す）
- `threads_channel_new(capacity)`（channel id を返す）
- `threads_send(channel_id, message)`（送信成功可否を返す）
- `threads_recv(channel_id)`（メッセージ受信。空時は `""`）
- `threads_spawn(name, channel_id)`（task id を返す）
- `threads_wait(task_id)`（終了コード `Int` を返す。現状は `0`）

### 5. std レイヤ分離（test-safe）

`vibe/std/threads.vibe` は、次の 2 層に分離している。

- pure contract 層（通常 `vibe test` で実行可能）
  - `task_spec`
  - `channel_spec`
  - `actor_spec`
  - `deployment_plan`
  - `recommended_wasm_flags` / `recommended_wasi_flags`
  - `recommended_wasm_env` / `recommended_wasi_env`
- runtime-gated 層（`--unstable-threads` 必須）
  - `probe_wat` (`threads_probe_wat` wrapper)
  - `runtime_hints` (`threads_runtime_hints` wrapper)
  - `channel_new` / `spawn` / `send` / `recv` / `wait`

## テスト

- `src/runtime/runtime_test.mbt`
  - `sleep` が `--unstable-async` なしで失敗
  - `await` が `--unstable-async` なしで失敗
  - `await` が `--unstable-async` 有効時に成功
  - 既存 `sleep` テストは `unstable_async_only()` を明示
  - `threads_probe_wat()` が `--unstable-threads` なしで失敗
  - `threads_probe_wat()` が `--unstable-threads` 有効時に成功
  - `threads_runtime_hints()` が `--unstable-threads` なしで失敗
  - `threads_runtime_hints()` が `--unstable-threads` 有効時に成功
  - `threads_channel_new` / `threads_send` が `--unstable-threads` なしで失敗
  - `threads_channel_new` / `threads_spawn` / `threads_send` / `threads_recv` / `threads_wait`
    が `--unstable-threads` 有効時に成功
  - channel capacity 超過時に `threads_send` が `false` を返す
- `src/cmd/vibe/cli_wbtest.mbt`
  - `parse_cli_runtime_args(...)` の default / opt-in パースを追加
- `vibe/std/threads_test.vibe`
  - pure contract 層（Task/Channel/Actor/Plan + `recommended_*`）を通常テストで実行
  - runtime-gated 層（`probe_wat` / `runtime_hints`）は thunk-only で未実行
- `just test`
  - async 例 (`examples/async.vibe`) 実行のため
    `vibe test --unstable-async ...` を利用

## 今後の実装計画

1. `--unstable-threads` の対象拡張
   - P0 完了: std 側に高級 API 契約（Task/Channel/Actor/Plan）を追加済み。
   - P1 完了: runtime 最小実体（`threads_channel_new/spawn/send/recv/wait`）を
     `--unstable-threads` で公開。
   - 次段階: 実スレッド実行（WASI Threads 実行基盤への接続）と
     メッセージ型の拡張（現状 `String` 固定）を段階的に実装する。
2. 診断強化
   - `FeatureDisabled` に対象 API 名と推奨 CLI 例を一貫表示する。
3. 安定化条件の明文化
   - 対応 target、回帰テスト、挙動互換ルールを満たした段階で
     flag remove を検討する。
