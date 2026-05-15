#!/usr/bin/env bash
# Heavy wasm tests (wasm_opt ~4min, wasm_runtime ~1min) — extracted from
# justfile `test-wasm-heavy`.
set -euo pipefail

source scripts/ensure_native_cli.sh
_build/native/debug/build/cmd/vibe/vibe.exe test vibe/wasm/wasm_opt vibe/wasm/wasm_runtime
