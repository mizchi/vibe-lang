#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/xsh_cli/xsh_cli.exe"
SCRIPT_PATH="$ROOT_DIR/bench/bench_simple.xsh"
WASM_OUT="$ROOT_DIR/target/bench/xsh_bench.wasm"

mkdir -p "$ROOT_DIR/target/bench"

moon build --target native --release src/xsh_cli

"$CLI_BIN" compile --wasm -o "$WASM_OUT" "$SCRIPT_PATH"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 3 "wasmtime run --invoke run $WASM_OUT >/dev/null"
else
  echo "hyperfine not found; using /usr/bin/time (10 runs)"
  for _ in $(seq 1 10); do
    /usr/bin/time -p wasmtime run --invoke run "$WASM_OUT" >/dev/null
  done
fi
