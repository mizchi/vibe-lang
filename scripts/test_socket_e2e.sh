#!/usr/bin/env bash
# Socket E2E test: start echo server, run vibe socket test, verify round-trip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PORT=18234
VIBE_CLI="${ROOT}/_build/native/debug/build/cmd/vibe/vibe.exe"

# Build CLI if needed
if [ ! -x "$VIBE_CLI" ]; then
  echo "Building native CLI..."
  (cd "$ROOT" && moon build --target native src/cmd/vibe --warn-list '-29-55')
fi

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start echo server
python3 "$ROOT/tests/echo_server.py" "$PORT" &
SERVER_PID=$!

# Wait for server to be ready (read port from stdout)
sleep 0.3

# Verify server is listening
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "FAIL: echo server failed to start"
  exit 1
fi

echo "Echo server running on 127.0.0.1:$PORT (pid=$SERVER_PID)"

# Run the socket e2e test
echo "Running socket E2E test..."
"$VIBE_CLI" test vibe/socket/socket_e2e_test.vibe

echo "PASS: socket E2E test succeeded"
