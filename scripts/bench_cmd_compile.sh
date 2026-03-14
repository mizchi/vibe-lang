#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
SCRIPT_PATH="${VIBE_BENCH_FILE:-$ROOT_DIR/bench/bench_simple.vibe}"

COUNT="${VIBE_BENCH_N:-1000}"
WARMUP="${VIBE_BENCH_WARMUP:-10}"

moon build --target native --release src/cmd/vibe

"$CLI_BIN" bench-file --n "$COUNT" --warmup "$WARMUP" "$SCRIPT_PATH"
