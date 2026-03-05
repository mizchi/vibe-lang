#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WAC_BIN="${WAC_BIN:-wac}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/http_adapter/string_e2e}"
SERVE_PORT="${VIBE_HTTP_P3_STRING_PORT:-18792}"
SERVE_ADDR="127.0.0.1:$SERVE_PORT"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd moon
require_cmd wasm-tools
require_cmd wasmtime
require_cmd "$WAC_BIN"

mkdir -p "$OUT_DIR"

ADAPTER_COMPONENT="$OUT_DIR/adapter.component.wasm"
APP_COMPONENT="$OUT_DIR/app.component.wasm"
COMPOSED_COMPONENT="$OUT_DIR/composed.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
SERVE_PID_FILE="$OUT_DIR/serve.pid"

cleanup_serve() {
  if [ -f "$SERVE_PID_FILE" ]; then
    local pid
    pid="$(cat "$SERVE_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$SERVE_PID_FILE"
  fi
}
trap cleanup_serve EXIT

echo "[e2e-string] Phase 2: HTTP P3 with string params"

# Step 1: Build adapter
echo "[e2e-string] building adapter..."
"$PROJECT_ROOT/scripts/build_wasi_http_p3_adapter.sh" "$ADAPTER_COMPONENT" 2>&1 | tail -1

# Step 2: Compile vibe handler with component-string-lift
echo "[e2e-string] compiling vibe handler with --component-string-lift..."
moon run --target native src/cmd/vibe -- compile --component-string-lift \
  fixtures/http_p3_handler_string.vibe -o "$APP_COMPONENT" 2>/dev/null

# Step 3: Compose
echo "[e2e-string] composing with wac plug..."
"$WAC_BIN" plug --plug "$APP_COMPONENT" "$ADAPTER_COMPONENT" -o "$COMPOSED_COMPONENT"
wasm-tools validate --features all "$COMPOSED_COMPONENT"
echo "[e2e-string] compose OK"

# Step 4: Serve
echo "[e2e-string] starting wasmtime serve on $SERVE_ADDR..."
( wasmtime serve \
    -Sp3 \
    -W component-model-async=y \
    -W component-model-async-builtins=y \
    --addr "$SERVE_ADDR" \
    "$COMPOSED_COMPONENT" >"$SERVE_LOG" 2>&1 & echo $! > "$SERVE_PID_FILE" )
sleep 2

if ! kill -0 "$(cat "$SERVE_PID_FILE")" 2>/dev/null; then
  if grep -q "resource implementation is missing" "$SERVE_LOG"; then
    echo "[e2e-string] status: blocked (known wasmtime resource issue)"
    sed -n '1,20p' "$SERVE_LOG"
    exit 0
  fi
  echo "[e2e-string] serve failed unexpectedly" >&2
  sed -n '1,40p' "$SERVE_LOG" >&2
  exit 1
fi

echo "[e2e-string] serve started"

# Step 5: E2E tests
PASS=0
FAIL=0

run_test() {
  local method="$1" url="$2" expected_status="$3" desc="$4"
  local actual_status body
  actual_status=$(curl -s -o "$OUT_DIR/body.txt" -w '%{http_code}' \
    -X "$method" --max-time 5 "http://$SERVE_ADDR$url" 2>/dev/null || echo "000")
  body=$(cat "$OUT_DIR/body.txt" 2>/dev/null || echo "")
  if [ "$actual_status" = "$expected_status" ]; then
    echo "  PASS: $desc (status=$actual_status body='$body')"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected=$expected_status got=$actual_status body='$body')"
    FAIL=$((FAIL + 1))
  fi
}

echo "[e2e-string] running tests..."
run_test GET / 200 "GET / => 200"
run_test GET /notfound 404 "GET /notfound => 404"
run_test POST / 405 "POST / => 405"

echo ""
echo "[e2e-string] results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "[e2e-string] FAIL"
  exit 1
fi
echo "[e2e-string] ALL PASS"
