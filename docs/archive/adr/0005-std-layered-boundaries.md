# ADR-0005: 標準ライブラリの階層型境界モデル

- Date: 2026-02-16
- Status: accepted

## Context

標準ライブラリ (`vibe/`) のモジュール間依存が複雑化し、循環依存や副作用の汚染リスクがあった。pure な型定義とエフェクトフルな I/O を明確に分離する必要があった。

## Decision

以下の層構造を定義し、各層は上位層のみを import 可能とする:

1. **trait-contract** — トレイト定義のみ（`builtin_traits.vibe`）
2. **pure-primitive** — 基本型（`int`, `string`, `bool`, `char`, `float`, `double`）
3. **pure-data** — データ構造（`array`, `option`, `result`, `bytes`）
4. **ref-model** — 参照モデル（`path`）
5. **effect-boundary** — I/O 境界（`io.vibe`, `threads.vibe`）

標準ライブラリ外のパッケージ:
- `vibe/collection` — リスト・マップ・セット
- `vibe/json` — JSON parser / JSON-RPC
- `vibe/base64` — Base64 encode/decode
- `vibe/sha1` — SHA-1 hash
- `vibe/fs` — ファイルシステム（WASI）
- `vibe/socket` — TCP ソケット（WASI P2）
- `vibe/http` — HTTP クライアント/サーバー
- `vibe/x` — 実験的パッケージ

## Consequences

- 層違反がコンパイル時に検出可能
- pure 層は WASM バックエンドでもそのまま利用できる
- 新規モジュール追加時にどの層に属するか判断が必要
