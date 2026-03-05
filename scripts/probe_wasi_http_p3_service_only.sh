#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/http_adapter/probe_service_only}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_service_only.XXXXXX)"
REQUIRE_READY="${VIBE_WASI_HTTP_P3_REQUIRE_READY:-0}"
SERVICE_COMPONENT="$OUT_DIR/service_only.component.wasm"
SERVE_LOG="$OUT_DIR/serve.log"
SERVE_PID_FILE="$OUT_DIR/serve.pid"

cleanup_tmp() {
  rm -rf "$TMP_DIR"
}

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

cleanup() {
  cleanup_serve
  cleanup_tmp
}

trap cleanup EXIT

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd cargo
require_cmd wasm-tools
require_cmd wasmtime

if [ -x "/Users/mz/.cargo/bin/cargo" ]; then
  export PATH="/Users/mz/.cargo/bin:$PATH"
fi

mkdir -p "$TMP_DIR/src"
mkdir -p "$OUT_DIR"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_http_p3_service_only"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.53.1", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:http-adapter;

      world serviceonly {
        include wasi:http/service@0.3.0-rc-2026-01-06;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-adapter/serviceonly",
    pub_export_macro: true,
    generate_all,
});

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Request, Response};

struct Component;

impl Guest for Component {
    async fn handle(_request: Request) -> Result<Response, ErrorCode> {
        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(Fields::new(), Some(body_rx), body_result_rx);
        drop(body_result_tx);

        wit_bindgen::spawn(async move {
            let remaining = body_tx.write_all(b"hello from wasi p3".to_vec()).await;
            assert!(remaining.is_empty());
        });
        Ok(resp)
    }
}

export!(Component);
EOF

echo "[probe] build service-only component"
pushd "$TMP_DIR" >/dev/null
cargo build --target wasm32-unknown-unknown --release
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_p3_service_only.wasm \
  -o "$SERVICE_COMPONENT"
popd >/dev/null

wasm-tools validate --features all "$SERVICE_COMPONENT"

SERVE_PORT="${VIBE_WASI_HTTP_P3_PORT:-18787}"
SERVE_ADDR="127.0.0.1:$SERVE_PORT"

echo "[probe] serve smoke on $SERVE_ADDR"
( wasmtime serve \
    -Sp3 \
    -W component-model-async=y \
    -W component-model-async-builtins=y \
    --addr "$SERVE_ADDR" \
    "$SERVICE_COMPONENT" >"$SERVE_LOG" 2>&1 & echo $! > "$SERVE_PID_FILE" )
sleep 2

if ! kill -0 "$(cat "$SERVE_PID_FILE")" 2>/dev/null; then
  if grep -q "resource implementation is missing" "$SERVE_LOG"; then
    echo "[probe] status: blocked"
    echo "[probe] known blocker: wasi:http/types resource impl mismatch"
    echo "[probe] component: $SERVICE_COMPONENT"
    echo "[probe] log:"
    sed -n '1,80p' "$SERVE_LOG"
    if [ "$REQUIRE_READY" = "1" ]; then
      echo "[probe] strict mode: failing because P3 serve is not ready" >&2
      exit 1
    fi
    exit 0
  fi
  echo "[probe] unexpected serve failure" >&2
  sed -n '1,120p' "$SERVE_LOG" >&2
  exit 1
fi

echo "[probe] status: ready"
echo "[probe] serve start: OK"
echo "[probe] component: $SERVICE_COMPONENT"

# e2e: send HTTP request and verify response
echo "[probe] e2e: sending request to http://$SERVE_ADDR/"
HTTP_STATUS=$(curl -s -o "$OUT_DIR/response_body.txt" -w '%{http_code}' "http://$SERVE_ADDR/" 2>/dev/null || echo "000")
RESPONSE_BODY=$(cat "$OUT_DIR/response_body.txt" 2>/dev/null || echo "")

echo "[probe] e2e: status=$HTTP_STATUS body='$RESPONSE_BODY'"

if [ "$HTTP_STATUS" = "200" ] && [ "$RESPONSE_BODY" = "hello from wasi p3" ]; then
  echo "[probe] e2e: PASS"
else
  echo "[probe] e2e: FAIL (expected 200 'hello from wasi p3', got $HTTP_STATUS '$RESPONSE_BODY')"
  echo "[probe] serve log:"
  sed -n '1,40p' "$SERVE_LOG"
  if [ "$REQUIRE_READY" = "1" ]; then
    exit 1
  fi
fi

cleanup_serve
