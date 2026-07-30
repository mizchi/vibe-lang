# vibe Examples

This directory contains runnable examples of vibe language features.

## Recommended Entry Point

- `basics.vibe`: minimal language tutorial (fundamentals)
- `syntax.vibe`: advanced syntax tour (Generics/Struct/Error/wasm types)

```bash
pkf run run -- test examples/basics.vibe
pkf run run -- test examples/syntax.vibe
```

## Language Features

- `effects.vibe`: `with { Error }` / `handle { ... } with Error { ... }`
- `async.vibe`: `await` and async effect combinations
- `perform_handle.vibe`: `perform Effect::Op(...)` + `handle` による多層エフェクト/回復パターン
- `effect_demo.vibe`: effect 宣言を名前で共有する複数関数パターン (#752)
- `module_export.vibe`, `module_import.vibe`: module export/import basics
- `module_types_export.vibe`, `module_types_import.vibe`: importing types from modules
- `trait_map_set.vibe`: map/set の trait パターン（`Hash` 境界と custom key adapter）
- `compiler_features.vibe`: selfhost compiler が使う言語機能のショーケース

## Standard Library Usage

- `base64.vibe`: base64 encode/decode の使用例
- `http_handler.vibe`: HTTP handler の書き方
- `json.vibe`: JSON の parse/build/query

## Bench

- `simple_bench.vibe`: `vibe bench` の最小例（詳細は
  [CONTRIBUTION.md の Bench セクション](../CONTRIBUTION.md#bench)）

```bash
pkf run run -- bench examples/simple_bench.vibe
```

## Core Library

- `vibe/prelude/`: vibe core library (self-hosted builtin modules)
- `vibe/prelude/io.vibe`: stream I/O + ANSI/TUI helpers for terminal-oriented examples

## WASM / Component Demos

- `wasm/sleep_demo.vibe`: async sleep demo (host support required)
- `wasm/sleep_async.vibe`, `wasm/read_async.vibe`: real async host demos
  (`sleep`/`Stdin::read_char` suspending across the guest/host boundary; see
  `scripts/test_real_async_host.sh` and `tools/async_host/`)
- `wasm/tui_stream_demo.vibe`: stdin/stdout stream TUI-style demo

```bash
pkf run demo-tui-stream
```

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
