#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
SCRIPT_PATH="$ROOT_DIR/bench/bench_simple.vibe"
WASM_OUT="$ROOT_DIR/target/bench/vibe_bench.wasm"

COUNT="${VIBE_BENCH_N:-5000000}"
WARMUP="${VIBE_BENCH_WARMUP:-1000}"
EXPR="${VIBE_BENCH_EXPR:-add(1,2)}"

mkdir -p "$ROOT_DIR/target/bench"

moon build --target native --release src/cmd/vibe

"$CLI_BIN" compile --wasm -o "$WASM_OUT" "$SCRIPT_PATH"

echo "[interp]"
"$CLI_BIN" bench --n "$COUNT" --warmup "$WARMUP" --expr "$EXPR"

echo "[wasmtime-resident]"
cargo run --release --manifest-path "$ROOT_DIR/tools/wasmtime_bench/Cargo.toml" -- \
  "$WASM_OUT" --n "$COUNT" --warmup "$WARMUP"
