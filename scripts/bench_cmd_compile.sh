#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI_BIN="$VIBE_CLI_BIN"
SCRIPT_PATH="${VIBE_BENCH_FILE:-$ROOT_DIR/bench/bench_simple.vibe}"

COUNT="${VIBE_BENCH_N:-1000}"
WARMUP="${VIBE_BENCH_WARMUP:-10}"



"$CLI_BIN" bench-file --n "$COUNT" --warmup "$WARMUP" "$SCRIPT_PATH"
