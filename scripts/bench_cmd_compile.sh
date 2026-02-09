#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/xsh/xsh.exe"
SCRIPT_PATH="${XSH_BENCH_FILE:-$ROOT_DIR/bench/bench_simple.xsh}"

COUNT="${XSH_BENCH_N:-1000}"
WARMUP="${XSH_BENCH_WARMUP:-10}"

moon build --target native --release src/cmd/xsh

"$CLI_BIN" bench-file --n "$COUNT" --warmup "$WARMUP" "$SCRIPT_PATH"
