# wasm/vibe

`wasm/vibe/vibe.wasm` は `src/lib` を `wasm-gc` release でビルドした配布用成果物です。

## Update

```bash
just build-wasm-vibe
```

GitHub Release 用の versioned asset をローカルで組むときは:

```bash
just build-release-assets v0.0.1
```

## Smoke test with wasmtime

```bash
just test-wasm-vibe-wasmtime
```

内部では以下を実行します:

```bash
wasmtime run -W gc=y -W function-references=y --invoke vibe_check wasm/vibe/vibe.wasm 1024 0 4096 4096
```
