# ADR-0035: Debug Adapter Protocol (DAP) 対応方針

- Date: 2026-03-27
- Status: proposed

## Context

vibe-lang はソースレベルデバッグ機能を持たない。ブレークポイント、ステップ実行、変数検査ができず、`println` デバッグに依存している。

一方で、カバレッジ計測システム (`--coverage`) が充実しており、ソース位置マッピング（byte span + line/col）、文レベル・分岐レベルのインストルメンテーション、`.wasm.cov.json` のサイドカーマップが既に存在する。

デバッグ情報のフォーマットとして DWARF と独自フォーマットの2択がある。

### DWARF の不採用理由

- C-like メモリモデル前提（スタック上のローカル変数、ポインタ）で vibe の i64 タグ付き値 + クロージャ ABI と impedance mismatch が大きい
- WASM DWARF は C/Rust コンパイラ向けに設計されており、カスタム言語ランタイムでは変数表示が意味をなさない
- 実装コストが膨大な割にツール互換性の恩恵が少ない（gdb/lldb で vibe をデバッグするユースケースがない）

### 既存カバレッジデータとの対応

| DAP 機能 | カバレッジデータ | ギャップ |
|----------|-----------------|---------|
| ブレークポイント位置 | coverage point (Line, Branch) + span | なし |
| ステップ実行 | 隣接 coverage point 間遷移 | 小（一時ブレーク設定） |
| 変数検査 | なし | 大（ローカル変数メタデータ未出力） |
| コールスタック | なし | 大（関数名マッピング未出力） |
| 実行制御 (pause/resume) | カウンタ加算のみ | 大（フック機構が必要） |

## Decision

DWARF を採用せず、既存のカバレッジインフラを拡張して独自 DAP サーバーを構築する。

### アーキテクチャ

```
[Editor (VSCode / JetBrains)]
      |  DAP protocol (JSON over stdio)
      v
[vibe-debug-adapter]  (Node.js プロセス)
      |
      |-- .wasm.cov.json   既存: ソース位置→coverage point マッピング
      |-- vibe.debug_map   新規: ローカル変数名→WASM local index (per point)
      |-- vibe.func_map    新規: 関数名→WASM func index + source span
      |
      v
[Instrumented WASM module]  (--debug フラグでコンパイル)
      |  import __vibe_dbg_break(point_id) -> i32
      v
[Node.js WASM Runtime]  (既存 wasm_vibe_host_runner.js 拡張)
```

### コンパイラ変更

`--debug` モードで coverage カウンタ加算の代わりに `call $__vibe_dbg_break(point_id)` を挿入:

- ブレークポイント未設定時: ホスト側 import が即 return（ゼロオーバーヘッド）
- ブレークポイント設定時: `SharedArrayBuffer + Atomics.wait` でブロック → DAP が resume するまで停止

### カスタムセクション

| セクション名 | 内容 | 用途 |
|-------------|------|------|
| `vibe.func_map` | `[{name, wasm_func_index, source_span}]` | コールスタック表示、関数ブレークポイント |
| `vibe.debug_map` | `[{point_id, locals: [{name, wasm_local_index, type}]}]` | 変数検査 |
| `vibe.error_map` | エラーコード→メッセージ（既存） | 例外表示 |
| `vibe.capabilities` | effect manifest（既存） | 権限表示 |

### 段階的実装

| Phase | 内容 | 0.1.0 | 既存データ活用 |
|-------|------|-------|---------------|
| P0 | `vibe.func_map` セクション + WASM name section 出力 | 対象 | codegen 関数テーブル |
| P1 | ブレークポイント DAP（停止・再開・ソース表示） | - | coverage point 再利用 |
| P2 | 変数検査（メタデータ出力 + メモリ読取） | - | `CodegenCtx` ローカル名配列 |
| P3 | ステップ実行（next / stepIn / stepOut） | - | 隣接 coverage point に一時ブレーク |
| P4 | Watch 式評価 | - | 式コンパイル + デバッグコンテキスト実行 |

### 参考

- [vain0x/debug-adapter-examples](https://github.com/vain0x/debug-adapter-examples) — DAP 実装の段階的サンプル
- [DAP Specification](https://microsoft.github.io/debug-adapter-protocol/specification) — プロトコル仕様
- `@vscode/debugadapter` npm パッケージ — Node.js DAP ライブラリ

## Consequences

**良い面:**

- カバレッジインフラの 80% を再利用でき、新規実装量が少ない
- vibe の型システム（タグ付き値、Option、enum）に最適化した変数表示が可能
- Node.js ベースの DAP サーバーで既存の wasm_vibe_host_runner.js を拡張するだけ
- DWARF 非依存のため、コンパイラが DWARF 仕様に縛られない
- P0 (func_map) は 0.1.0 で低コストで入る

**悪い面:**

- Chrome DevTools / wasmtime の DWARF デバッグとは互換しない
- DAP サーバーを自前で保守する必要がある
- `SharedArrayBuffer + Atomics.wait` のブロック機構は WASM スレッド対応が前提（Node.js では利用可能）
- gdb/lldb からのデバッグは不可能（vibe 専用ツールチェーンが必要）
