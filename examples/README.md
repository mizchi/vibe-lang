# vibe Examples

This directory contains runnable examples of vibe language features.

## Recommended Entry Point

- `basics.vibe`: minimal language tutorial (fundamentals)
- `syntax.vibe`: advanced syntax tour (Generics/Struct/Exception/wasm types)

```bash
vibe test examples/basics.vibe
vibe test examples/syntax.vibe
```

## Language Features

- `effects.vibe`: `with Exception` / `handle { ... } with { Exception::Throw(_) => ... }`
- `async.vibe`: `await` and async effect combinations
- `perform_handle.vibe`: layered effects and recovery with `perform Effect::Op(...)` and `handle`
- `effect_demo.vibe`: functions sharing a named effect declaration (#752)
- `module_export.vibe`, `module_import.vibe`: module export/import basics
- `module_types_export.vibe`, `module_types_import.vibe`: importing types from modules
- `trait_map_set.vibe`: map/set traits with a `Hash` bound and custom key adapter
- `compiler_features.vibe`: language features used by the self-hosted compiler

## Standard Library Usage

- `base64.vibe`: base64 encoding and decoding
- `http_handler.vibe`: writing an HTTP handler
- `json.vibe`: JSON parsing, construction, and queries

## Bench

- `simple_bench.vibe`: minimal `vibe bench` example (see the
  [Bench section in CONTRIBUTION.md](../CONTRIBUTION.md#bench))

```bash
vibe bench examples/simple_bench.vibe
```

## Core Library

- `@vibe/builtin/`: vibe core library (self-hosted builtin modules)
- `@vibe/builtin/io.vibe`: stream I/O + ANSI/TUI helpers for terminal-oriented examples

## WASM / Component Demos

- `wasm/sleep_demo.vibe`: async sleep demo (host support required)
- `wasm/sleep_async.vibe`, `wasm/read_async.vibe`: real async host demos
  (`sleep`/`Stdin::read_char` suspending across the guest/host boundary; see
  `scripts/test_real_async_host.sh` and `tools/async_host/`)
- `wasm/tui_stream_demo.vibe`: stdin/stdout stream TUI-style demo

## Test Fixtures

Regression-test fixtures (`*_test.vibe` files exercised via the selfhost
unit-test battery) used to live in this directory. They moved to
[`fixtures/`](../fixtures/) (#880) so `examples/` only contains material
worth reading as a tutorial. `scripts/unit_test_runner.sh` discovers every
`*_test.vibe` under `examples/`, `lib/`, and `fixtures/` unconditionally
(no allowlist file, #1231) -- run `scripts/unit_test_runner.sh --list` to
see the corpus, or check that script's `EXCLUDE_PATTERNS` for the handful
of deliberately-excluded exceptions. See `CONTRIBUTION.md`'s "Fixtures"
section for the fixture layout convention.
