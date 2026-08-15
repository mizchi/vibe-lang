#!/usr/bin/env bash
set -euo pipefail

# #1540 probe gate: can the request body reach the guest as a `stream<u8>`
# PARAMETER on the handler import, rather than being collected into a String by
# the adapter first?
#
# See tools/wasip3_component_probe/http_body_stream/README.md for why this shape
# and not the one #1540's scope bullets describe (that one is a composition
# cycle; `wac plug` silently leaves the second edge unsatisfied and `wac
# compose` cannot express it at all).
#
# Pipeline under test:
#   1. build a Rust wasi-http P3 adapter whose guest import is
#        handler: func(method: string, url: string, headers: string,
#                      body: stream<u8>) -> string
#      and which hands `Request::consume_body`'s reader straight through --
#      no `.collect().await`.
#   2. componentize + validate it.
#   3. `wac plug` the hand-written probe guest into it; the composed component
#      must have NO unsatisfied import beyond what the host provides.
#   4. `wasmtime serve` it; a POST WITH A BODY must get 200 and the guest's
#      answer.
#
# The guest ignores the stream -- this gate answers the composition question,
# not the stream-read one. Reading it needs `stream.read` plus an async lift,
# and the emitters are too narrow for that today (README, last section).
#
# Skips cleanly when cargo / wasm-tools / wac / wasmtime / curl are missing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROBE_DIR="$PROJECT_ROOT/tools/wasip3_component_probe/http_body_stream"
OUT_DIR="$PROJECT_ROOT/_build/bench/http_body_stream_probe/run-$$"
SERVE_LOG="$OUT_DIR/serve.log"
# Separate concurrent probe runs without relying on a repository-global fixed
# port. More importantly, the response token below proves that curl reached
# THIS process, not an incumbent listener which happened to answer similarly.
PORT=$((20000 + ($$ % 20000)))
ADDR="${VIBE_HTTP_BODY_STREAM_PROBE_ADDR:-127.0.0.1:$PORT}"
RESPONSE_TOKEN="probe-$(printf '%05d' $(( $$ % 100000 )))"

if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[body-stream-probe] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[body-stream-probe] SKIP: $1 not found"; exit 0
}
for c in cargo wasm-tools wac curl; do
  command -v "$c" >/dev/null 2>&1 || missing_tool "$c"
done
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  missing_tool "wasmtime"
fi

WIT_PATH="$PROJECT_ROOT/lib/@vibe/wasi/wit/p3"
if [ ! -f "$WIT_PATH/world.wit" ]; then
  WIT_PATH="$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit"
fi
[ -f "$WIT_PATH/world.wit" ] || missing_tool "wasi:http p3 WIT"

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_body_stream_adapter.XXXXXX")"
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
mkdir -p "$TMP_DIR/src"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_body_stream_probe_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:body-stream-probe;

      world adapter {
        /// #1540 shape (a): the body arrives as a stream PARAMETER. The
        /// adapter never materializes it.
        import handler: func(method: string, url: string, headers: string, body: stream<u8>) -> string;
        include wasi:http/service@0.3.0;
      }
    "#,
    path: "$WIT_PATH",
    world: "vibe:body-stream-probe/adapter",
    pub_export_macro: true,
    generate_all,
});

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Request, Response};

struct Component;

impl Guest for Component {
    async fn handle(request: Request) -> Result<Response, ErrorCode> {
        let url = request.get_path_with_query().unwrap_or_else(|| "/".to_string());
        let (_, result_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
        // The point of the probe: hand the READER over, no .collect().await.
        let (req_body_rx, _trailers_rx) = Request::consume_body(request, result_rx);
        let raw = handler("GET", &url, "", req_body_rx);

        let fields = Fields::new();
        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(fields, Some(body_rx), body_result_rx);
        resp.set_status_code(200).map_err(|_| ErrorCode::InternalError(None))?;
        drop(body_result_tx);
        wit_bindgen::spawn(async move {
            let remaining = body_tx.write_all(raw.into_bytes()).await;
            assert!(remaining.is_empty());
        });
        Ok(resp)
    }
}

export!(Component);
EOF

echo "[body-stream-probe] building the stream-param adapter"
(cd "$TMP_DIR" && cargo build --target wasm32-unknown-unknown --release >/dev/null 2>&1) || {
  echo "[body-stream-probe] FAILED: adapter did not build -- wit-bindgen no longer accepts a stream<u8> parameter on an imported func?" >&2
  (cd "$TMP_DIR" && cargo build --target wasm32-unknown-unknown --release 2>&1 | tail -20) >&2
  exit 1
}

ADAPTER="$OUT_DIR/adapter.component.wasm"
wasm-tools component new \
  "$TMP_DIR/target/wasm32-unknown-unknown/release/vibe_body_stream_probe_adapter.wasm" \
  -o "$ADAPTER"
wasm-tools validate --features all "$ADAPTER"
if ! wasm-tools component wit "$ADAPTER" | grep -qF 'body: stream<u8>'; then
  echo "[body-stream-probe] FAILED: the adapter does not declare a stream<u8> body import" >&2
  wasm-tools component wit "$ADAPTER" >&2
  exit 1
fi
echo "[body-stream-probe] adapter imports handler(.., body: stream<u8>)"

GUEST="$OUT_DIR/guest.wasm"
sed "s/probe-00000/$RESPONSE_TOKEN/" "$PROBE_DIR/guest.wat" >"$TMP_DIR/guest.wat"
wasm-tools parse "$TMP_DIR/guest.wat" -o "$GUEST"
wasm-tools validate --features all "$GUEST"
echo "[body-stream-probe] probe guest validates"

COMPOSED="$OUT_DIR/composed.wasm"
wac plug --plug "$GUEST" "$ADAPTER" -o "$COMPOSED"
wasm-tools validate --features all "$COMPOSED"

# The cycle shape's failure mode was a composed component that still IMPORTS
# what it was supposed to have been handed. Assert the stronger documented
# contract: the root world has exactly the one host-provided HTTP import.
COMPOSED_WIT="$(wasm-tools component wit "$COMPOSED")"
ROOT_IMPORTS="$(printf '%s\n' "$COMPOSED_WIT" | awk '
  /^world root \{$/ { in_world = 1; next }
  in_world && /^}/ { exit }
  in_world && /^[[:space:]]+import / {
    sub(/^[[:space:]]+/, "")
    print
  }
')"
if [ "$ROOT_IMPORTS" != 'import wasi:http/types@0.3.0;' ]; then
  echo "[body-stream-probe] FAILED: composed root imports are not exactly the host-provided wasi:http/types edge" >&2
  printf '%s\n' "$COMPOSED_WIT" | head -20 >&2
  exit 1
fi
echo "[body-stream-probe] composed: handler edge connected; only host wasi:http/types remains"

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPOSED" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
ready=0
for _ in $(seq 1 40); do
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "[body-stream-probe] FAILED: spawned wasmtime exited before accepting requests" >&2
    cat "$SERVE_LOG" >&2 || true
    exit 1
  fi
  if curl -s -m 1 -o /dev/null "http://$ADDR/" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" != "1" ]; then
  echo "[body-stream-probe] FAILED: spawned wasmtime did not become ready at $ADDR" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

RESPONSE_FILE="$TMP_DIR/response.txt"
CODE="$(curl -sS --max-time 10 -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST --data-binary "hello-body" "http://$ADDR/probe" 2>&1 || true)"
OUT="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
if ! kill -0 "$SERVE_PID" 2>/dev/null; then
  echo "[body-stream-probe] FAILED: spawned wasmtime exited while serving the probe request" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

if [ "$CODE" != "200" ]; then
  echo "[body-stream-probe] FAILED: POST with a body returned '$CODE' (want 200)" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
if ! printf '%s' "$OUT" | grep -qF "$RESPONSE_TOKEN"; then
  echo "[body-stream-probe] FAILED: response body was '$OUT' (want this guest's '$RESPONSE_TOKEN')" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

echo "[body-stream-probe] POST with a body -> 200, guest answered"
echo "[body-stream-probe] PASS: a wasi:http request body can reach the guest as a stream<u8> parameter (#1540)"
