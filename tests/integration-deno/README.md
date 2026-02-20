# Deno Integration Tests

このディレクトリは、`src/lib` から生成した wasm-gc 成果物を Deno で `js/vibe/index.js` バインディング経由で検証する統合テストです。

- 対象成果物: `_build/wasm-gc/release/build/lib/lib.wasm`
- エクスポート: `vibe_init`, `vibe_check`, `vibe_check_project`, `vibe_format`, `vibe_ide_outline`, `vibe_ide_peek_def`, `vibe_ide_search`, `memory`
- `js/vibe/index.js` バインディング経由で呼び出す（`createVibeService({ bootstrap })` / `service.init(...)` で prelude + kv 初期注入対応）
- `createVibeService({ wasmModule })` で事前コンパイル済み `WebAssembly.Module` を受け取れる（Cloudflare 向けの module instantiate 経路）
- `ideOutline` / `idePeekDef` / `ideSearch` で `vibe ide` 相当 API を提供
- `checkProject({ entry, files })` で project API を提供（import 解決対応）
- テスト内で `Deno.Command` は使わず、成果物だけを読む

実行:

```bash
just test-integration-deno
just coverage-deno

# 手元で JS CLI を試す
just ide-js outline /path/to/file.vibe
# CLI は相対 import を再帰で収集して project request を組み立てる
```

`just coverage-deno` は以下を生成:
- `_build/coverage/deno/summary.txt`
- `_build/coverage/deno/lcov.info`
- `_build/coverage/deno/html/index.html`
