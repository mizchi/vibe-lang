#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WAC_BIN="${WAC_BIN:-wac}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/http_adapter/probe}"
REQUIRE_READY="${VIBE_WASI_HTTP_P3_REQUIRE_READY:-0}"

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

ADAPTER_COMPONENT="$OUT_DIR/vibe_http_p3_adapter.component.wasm"
APP_SRC="$OUT_DIR/run_app.vibe"
APP_COMPONENT="$OUT_DIR/run_app.component.wasm"
COMPOSED_COMPONENT="$OUT_DIR/vibe_http_p3_composed.component.wasm"
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

echo "[probe] build p3 adapter component"
scripts/build_wasi_http_p3_adapter.sh "$ADAPTER_COMPONENT"

cat >"$APP_SRC" <<'EOF'
let run = () -> Int {
  42
}
run()
EOF

echo "[probe] build app component"
moon run --target native src/cmd/vibe -- compile --component "$APP_SRC" -o "$APP_COMPONENT"

echo "[probe] compose with $WAC_BIN"
"$WAC_BIN" plug --plug "$APP_COMPONENT" "$ADAPTER_COMPONENT" -o "$COMPOSED_COMPONENT"
wasm-tools validate --features all "$COMPOSED_COMPONENT"

echo "[probe] serve smoke (2s)"
( wasmtime serve \
    -W component-model-async=y \
    -W component-model-async-builtins=y \
    --addr 127.0.0.1:0 \
    "$COMPOSED_COMPONENT" >"$SERVE_LOG" 2>&1 & echo $! > "$SERVE_PID_FILE" )
sleep 2

if kill -0 "$(cat "$SERVE_PID_FILE")" 2>/dev/null; then
  cleanup_serve
  echo "[probe] status: ready"
  echo "[probe] serve start: OK"
  echo "[probe] composed component: $COMPOSED_COMPONENT"
  exit 0
fi

if grep -q "resource implementation is missing" "$SERVE_LOG"; then
  echo "[probe] status: blocked"
  echo "[probe] known blocker: wasi:http/types resource impl mismatch"
  echo "[probe] composed component: $COMPOSED_COMPONENT"
  echo "[probe] log:"
  sed -n '1,80p' "$SERVE_LOG"
  if [ "$REQUIRE_READY" = "1" ]; then
    echo "[probe] strict mode: failing because P3 compose/serve is not ready" >&2
    exit 1
  fi
  exit 0
fi

echo "[probe] unexpected serve failure" >&2
sed -n '1,120p' "$SERVE_LOG" >&2
exit 1
