#!/usr/bin/env bash
set -euo pipefail

PORT=18280
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ensure_native_cli.sh"
VIBE="$VIBE_CLI_BIN"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== HTTP E2E Tests ==="


# Start HTTP echo server
echo "Starting HTTP echo server on port $PORT..."
python3 tests/http_echo_server.py "$PORT" &
SERVER_PID=$!
sleep 1

# Verify server is running
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: HTTP echo server failed to start"
  exit 1
fi

# Run client E2E tests
echo "Running HTTP client E2E tests..."
$VIBE fetch vibe/http/http_e2e_test.vibe 2>/dev/null || true
$VIBE test vibe/http/http_e2e_test.vibe

echo ""
echo "=== All HTTP E2E tests passed ==="
