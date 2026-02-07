# xsh Examples

This directory contains runnable examples of xsh language features.

## Recommended Entry Point

- `basics.xsh`: minimal language tutorial (fundamentals)
- `syntax.xsh`: advanced syntax tour (Generics/Struct/Error/wasm types)

```bash
just run test examples/basics.xsh
just run test examples/syntax.xsh
```

## Language Features

- `effects.xsh`: `with {Error}` / `try { ... } catch { ... }`
- `async.xsh`: `await` and async effect combinations
- `module_export.xsh`, `module_import.xsh`: module export/import basics
- `module_types_export.xsh`, `module_types_import.xsh`: importing types from modules
- `pattern_coverage.xsh`: exhaustive pattern coverage examples

## Standard Library Draft

- `std/`: self-hosted std modules (`int`, `float`, `list`, `option`, `string`, ...)
- `std/wasm/types.xsh`: wasm-facing type aliases (`I32`/`F32`/`F64`)
- `std/wasm/opcodes.xsh`: wasm opcode-style APIs (`i32_add`, `f64_promote_f32`, ...)
- `std/wasm/io_stream.xsh`: component-friendly stream I/O helpers

## WASM / Component Demos

- `wasm/sleep_demo.xsh`: async sleep demo (host support required)
- `wasm/tui_stream_demo.xsh`: stdin/stdout stream TUI-style demo

```bash
just demo-tui-stream
```
