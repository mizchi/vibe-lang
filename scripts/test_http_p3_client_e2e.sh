#!/usr/bin/env bash
set -euo pipefail

# E2E test for HTTP P3 Phase 3: combined adapter with client proxy.
# Tests that the combined adapter can:
# 1. Handle direct responses (vibe handler returns status code)
# 2. Make outgoing HTTP client requests (vibe handler returns -1 for proxy)
#
# Architecture:
#   [curl] → [wasmtime serve (combined adapter + vibe)] → [backend server]
#           handler direction ↑                          ↑ client direction

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/http_adapter/client_e2e}"
SERVE_PORT="${VIBE_HTTP_P3_CLIENT_PORT:-18793}"
BACKEND_PORT="${VIBE_HTTP_P3_BACKEND_PORT:-18794}"
SERVE_ADDR="127.0.0.1:$SERVE_PORT"
BACKEND_ADDR="127.0.0.1:$BACKEND_PORT"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd moon
require_cmd wasm-tools
require_cmd wasmtime
require_cmd wac
require_cmd python3

mkdir -p "$OUT_DIR"

ADAPTER_COMPONENT="$OUT_DIR/combined_adapter.component.wasm"
APP_COMPONENT="$OUT_DIR/app.component.wasm"
COMPOSED_COMPONENT="$OUT_DIR/composed.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
SERVE_PID_FILE="$OUT_DIR/serve.pid"
BACKEND_PID_FILE="$OUT_DIR/backend.pid"

cleanup() {
  for pidfile in "$SERVE_PID_FILE" "$BACKEND_PID_FILE"; do
    if [ -f "$pidfile" ]; then
      local pid
      pid="$(cat "$pidfile")"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" || true
        wait "$pid" 2>/dev/null || true
      fi
      rm -f "$pidfile"
    fi
  done
}
trap cleanup EXIT

echo "[e2e-client] Phase 3: HTTP P3 with client proxy"

# Step 1: Build combined adapter
echo "[e2e-client] building combined adapter..."
"$PROJECT_ROOT/scripts/build_wasi_http_p3_combined_adapter.sh" "$ADAPTER_COMPONENT" 2>&1 | tail -1

# Step 2: Compile vibe handler with component-string-lift
echo "[e2e-client] compiling vibe handler with --component-string-lift..."
moon run --target native src/cmd/vibe -- compile --component-string-lift \
  fixtures/http_p3_client_proxy.vibe -o "$APP_COMPONENT" 2>/dev/null

# Step 3: Compose (use wac compose --no-validate + binary patch for async func type)
# wac 0.9/0.10 doesn't support async CM functions yet, so we:
#   1. compose with --no-validate (wac drops async flag on client.send)
#   2. binary-patch the sync func type (0x40) to async (0x43) for client.send
#   3. validate with wasm-tools which handles async correctly
echo "[e2e-client] composing with wac compose..."
WAC_FILE="$OUT_DIR/compose.wac"
cat >"$WAC_FILE" <<'WACEOF'
package test:composed;
let app = new vibe:app {};
let adapter = new vibe:adapter { handler: app.handler, ... };
export adapter...;
WACEOF
wac compose \
  -d "vibe:app=$APP_COMPONENT" \
  -d "vibe:adapter=$ADAPTER_COMPONENT" \
  --no-validate \
  -o "$COMPOSED_COMPONENT" \
  "$WAC_FILE"

echo "[e2e-client] patching async func type for wasi:http/client.send..."
python3 -c "
import re, sys
data = bytearray(open('$COMPOSED_COMPONENT', 'rb').read())
# Find the sync func type (0x40) followed by param 'request' in the outer import type.
# Pattern: 0x40 0x01 0x07 'request' (sync func with 1 param named 'request')
pattern = b'\x40\x01\x07request'
matches = [m.start() for m in re.finditer(re.escape(pattern), data)]
if len(matches) < 1:
    print('ERROR: could not find sync send func type to patch', file=sys.stderr)
    sys.exit(1)
# Patch the FIRST occurrence (outer import type)
offset = matches[0]
data[offset] = 0x43  # async func type
open('$COMPOSED_COMPONENT', 'wb').write(bytes(data))
print(f'patched offset 0x{offset:x}: 0x40 -> 0x43')
"

wasm-tools validate --features all "$COMPOSED_COMPONENT"
echo "[e2e-client] compose OK"

# Step 4: Start backend HTTP server (simple python)
echo "[e2e-client] starting backend server on $BACKEND_ADDR..."
python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'hello from backend')
    def log_message(self, *args):
        pass
socketserver.TCPServer.allow_reuse_address = True
s = socketserver.TCPServer(('127.0.0.1', $BACKEND_PORT), H)
s.serve_forever()
" &
echo $! > "$BACKEND_PID_FILE"
sleep 1

if ! kill -0 "$(cat "$BACKEND_PID_FILE")" 2>/dev/null; then
  echo "[e2e-client] backend failed to start" >&2
  exit 1
fi
echo "[e2e-client] backend started"

# Step 5: Serve the composed component
echo "[e2e-client] starting wasmtime serve on $SERVE_ADDR..."
( wasmtime serve \
    -Sp3 \
    -W component-model-async=y \
    -W component-model-async-builtins=y \
    --addr "$SERVE_ADDR" \
    "$COMPOSED_COMPONENT" >"$SERVE_LOG" 2>&1 & echo $! > "$SERVE_PID_FILE" )
sleep 2

if ! kill -0 "$(cat "$SERVE_PID_FILE")" 2>/dev/null; then
  echo "[e2e-client] serve failed" >&2
  sed -n '1,40p' "$SERVE_LOG" >&2
  exit 1
fi
echo "[e2e-client] serve started"

# Step 6: E2E tests
PASS=0
FAIL=0

run_test() {
  local method="$1" url="$2" expected_status="$3" desc="$4" expected_body="${5:-}"
  local actual_status body
  actual_status=$(curl -s -o "$OUT_DIR/body.txt" -w '%{http_code}' \
    -X "$method" --max-time 5 "http://$SERVE_ADDR$url" 2>/dev/null || echo "000")
  body=$(cat "$OUT_DIR/body.txt" 2>/dev/null || echo "")
  local status_ok=true body_ok=true
  if [ "$actual_status" != "$expected_status" ]; then
    status_ok=false
  fi
  if [ -n "$expected_body" ] && ! echo "$body" | grep -q "$expected_body"; then
    body_ok=false
  fi
  if $status_ok && $body_ok; then
    echo "  PASS: $desc (status=$actual_status)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected=$expected_status/$expected_body got=$actual_status body='$body')"
    FAIL=$((FAIL + 1))
  fi
}

echo "[e2e-client] running tests..."

# Direct response tests (same as Phase 2)
run_test GET / 200 "GET / => 200 (direct)"
run_test GET /health 200 "GET /health => 200 (direct)"
run_test GET /notfound 404 "GET /notfound => 404 (direct)"
run_test POST / 405 "POST / => 405 (direct)"

# Client proxy test: handler returns -1, adapter makes outgoing GET to backend
run_test GET "/proxy?target=http://$BACKEND_ADDR/backend" 200 "GET /proxy => 200 (client proxy)" "hello from backend"

echo ""
echo "[e2e-client] results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "[e2e-client] FAIL"
  exit 1
fi
echo "[e2e-client] ALL PASS"
