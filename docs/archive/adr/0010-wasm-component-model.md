# ADR-0010: WASM Component Model / WIT 統合

- Date: 2026-02-16
- Status: accepted

## Context

WASM モジュール単体ではホスト環境との I/O インタフェースが標準化されない。WASI Preview 2 の Component Model を採用することで、相互運用可能なコンポーネントとして配布できる可能性がある。

## Decision

vibe コンパイラに Component Model ターゲットを追加する:

```bash
vibe compile --component script.vibe -o out.component.wasm
vibe compile --wit-component script.vibe -o out.wit
```

- stdio ビルトインを `wasi:cli/stdin|stdout` + `wasi:io/streams` にマッピング
- エフェクト（sleep, shell, path, IO 等）をホスト import としてワイヤリング
- wasmtime または moonix で実行可能

実行:
```bash
just component-run examples/wasm/hello.vibe
just component-run-moonix examples/wasm/hello.vibe
```

## 発展方針

ADR-0021 で `#import` ディレクティブを使い、エフェクト宣言と
Component Model import を型レベルで統合する計画がある。本 ADR の手動ワイヤリングを
自動化し、export 関数のエフェクトセットから world を自動導出する:

```
#import("wasi:filesystem/read@0.2.0")
effect Fs { read_file(path: String) -> String }

export let main = () -> Unit with { Fs } { ... }
// → world の import wasi:filesystem/read@0.2.0 を自動導出
```

本 ADR の `--component` コンパイルフローは維持し、`#import` による自動化をその上に
追加する形とする。

## Consequences

- 標準的な WASM コンポーネントとして他ツール・言語と合成可能
- wasmtime の Component Model サポートに依存する
- WASI Preview 3（async サポート）への移行パスが開ける
- WIT 定義の自動生成により、外部連携のボイラープレートが削減される
