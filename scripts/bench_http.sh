#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/_build/native/debug/build/cmd/vibe/vibe.exe"
PORT=18281
N="${VIBE_BENCH_HTTP_N:-50}"
WARMUP="${VIBE_BENCH_HTTP_WARMUP:-5}"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== HTTP Benchmark ==="

# Build CLI if needed
if [ ! -f "$CLI_BIN" ]; then
  echo "Building vibe (debug)..."
  (cd "$ROOT_DIR" && moon build --target native src/cmd/vibe --warn-list '-29')
fi

# Start HTTP echo server
echo "Starting HTTP echo server on port $PORT..."
python3 "$ROOT_DIR/tests/http_echo_server.py" "$PORT" &
SERVER_PID=$!
sleep 1

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: HTTP echo server failed to start"
  exit 1
fi

# Fetch dependencies
"$CLI_BIN" fetch "$ROOT_DIR/bench/http_bench.vibe" 2>/dev/null || true

# Run benchmark (interpreter only — HTTP builtins are native)
echo "Running HTTP benchmarks (n=$N, warmup=$WARMUP)..."
echo ""
"$CLI_BIN" bench --backend interpreter --n "$N" --warmup "$WARMUP" "$ROOT_DIR/bench/http_bench.vibe"

echo ""
echo "=== HTTP Benchmark complete ==="
