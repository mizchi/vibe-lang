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
- `module_export.vibe`, `module_import.vibe`: module export/import basics
- `module_types_export.vibe`, `module_types_import.vibe`: importing types from modules
- `pattern_coverage.vibe`: exhaustive pattern coverage examples

## Core Library

- `vibe/std/`: vibe core library (self-hosted std modules)
- `vibe/std/wasm/types.vibe`: wasm-facing type aliases (`I32`/`F32`/`F64`)
- `vibe/std/wasm/opcodes.vibe`: wasm opcode-style APIs (`i32_add`, `f64_promote_f32`, ...)
- `vibe/std/wasm/io_stream.vibe`: component-friendly stream I/O helpers

## WASM / Component Demos

- `wasm/sleep_demo.vibe`: async sleep demo (host support required)
- `wasm/tui_stream_demo.vibe`: stdin/stdout stream TUI-style demo

```bash
just demo-tui-stream
```
