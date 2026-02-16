# ADR-0002: マルチバックエンド・コンパイル戦略

- Date: 2026-02-16
- Status: accepted

## Context

vibe プログラムの実行方式を決定する必要があった。単一バックエンドでは対応できるユースケースが限定されるため、複数バックエンドを用意する方針を検討した。

## Decision

以下のバックエンドをサポートする:

| バックエンド | フラグ | 用途 |
|---|---|---|
| インタプリタ (native) | `vibe run` | 開発時の高速実行、REPL、FFI 対応 |
| WASM MVP | `--wasm-mvp` | ポータブルな配布バイナリ |
| WASM-GC | `--wasm` / `--wasm-gc` | GC 対応ランタイム向け |
| WASM + js-string | `--wasm-js-string` | ブラウザ向け最適化 |
| Component Model | `--component` | WASI P2 コンポーネント合成 |

インタプリタをリファレンス実装とし、WASM バックエンドとの出力一致を `test-interpreter-wasm` で検証する。

## Consequences

- 各バックエンドの機能差（BackendLimit）を型レベルで管理する必要がある
- codegen テストのマトリクスが増加するが、一致テストにより品質を担保できる
- ユーザーは用途に応じたバックエンドを選択可能
