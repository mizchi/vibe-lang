# vibe Examples

This directory contains runnable examples of vibe language features.

## Recommended Entry Point

- `basics.vibe`: minimal language tutorial (fundamentals)
- `syntax.vibe`: advanced syntax tour (Generics/Struct/Error/wasm types)

```bash
just run test examples/basics.vibe
just run test examples/syntax.vibe
```

## Language Features

- `effects.vibe`: `with {Error}` / `try { ... } catch { ... }`
- `async.vibe`: `await` and async effect combinations
- `perform_handle.vibe`: `perform(...)` + `handle` による多層エフェクト/回復パターン
- `module_export.vibe`, `module_import.vibe`: module export/import basics
- `module_types_export.vibe`, `module_types_import.vibe`: importing types from modules
- `pattern_coverage.vibe`: exhaustive pattern coverage examples
- `trait_map_set.vibe`: map/set の trait パターン（`Hash` 境界と custom key adapter）

## Core Library

- `vibe/builtin/`: vibe core library (self-hosted builtin modules)
- `vibe/builtin/io.vibe`: stream I/O + ANSI/TUI helpers for terminal-oriented examples

## WASM / Component Demos

- `wasm/sleep_demo.vibe`: async sleep demo (host support required)
- `wasm/tui_stream_demo.vibe`: stdin/stdout stream TUI-style demo

```bash
just demo-tui-stream
```
