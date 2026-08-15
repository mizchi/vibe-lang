#!/usr/bin/env bash
set -euo pipefail

# #1540 scope 1 gate: does a guest that actually READS the request body work,
# end to end, over real HTTP?
#
# test_http_body_stream_probe_gate.sh answers the composition question with a
# guest that ignores the stream and answers a constant. This one asserts the
# stronger property that scope 4 has to be built on: the bytes POSTed by curl
# come back in the response, having been pulled out of the stream by the guest
# one `stream.read` at a time.
#
# tools/wasip3_component_probe/http_body_read/guest.wat carries the rationale
# and the two measurements this gate keeps true:
#
#   1. the adapter's import must be spelled `async func` in WIT -- reading the
#      body blocks, so the handler has to be async-lifted, and `canon lift ...
#      async` validates only against an async functype;
#   2. the stream parameter arrives as ONE i32 handle after the strings'
#      (ptr, len) pairs, and the core function returns nothing.
#
# The response body is the request body, so a passing run cannot be satisfied
# by a constant: the assertion is on a per-process token that only THIS
# invocation POSTs.
#
# Skips cleanly when cargo / wasm-tools / wac / wasmtime / curl are missing, and
# fails instead under VIBE_P3_GATE_REQUIRE_TOOLS=1, matching the other P3 probes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROBE_DIR="$PROJECT_ROOT/tools/wasip3_component_probe/http_body_read"
OUT_DIR="$PROJECT_ROOT/_build/bench/http_body_read_probe/run-$$"
SERVE_LOG="$OUT_DIR/serve.log"
# Per-process port and body token, for the same reason as the sibling probe: a
# different server already listening cannot satisfy the assertion or be killed
# by cleanup.
PORT=$((20000 + ($$ % 20000)))
ADDR="${VIBE_HTTP_BODY_READ_PROBE_ADDR:-127.0.0.1:$PORT}"
BODY_TOKEN="vibe-body-$(printf '%05d' $(( $$ % 100000 )))"

if [ -n "${VIBE_HTTP_GATE_WASMTIME_FLAGS:-}" ]; then
  read -r -a WASM_FLAGS <<<"$VIBE_HTTP_GATE_WASMTIME_FLAGS"
else
  WASM_FLAGS=(-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)
fi

missing_tool() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "[body-read-probe] FAILED: $1 not found (required mode)" >&2; exit 1
  fi
  echo "[body-read-probe] SKIP: $1 not found"; exit 0
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
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_body_read_adapter.XXXXXX")"
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
name = "vibe_body_read_probe_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

# The one line that differs from the sibling adapter -- and the measurement
# this gate exists to keep: `async func`, not `func`. With a plain `func` the
# import's functype is async_: false and the guest's `canon lift ... async` is
# rejected against it, so a guest that has to suspend to read the body cannot
# be plugged in at all.
cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:body-read-probe;

      world adapter {
        import handler: async func(method: string, url: string, headers: string, body: stream<u8>) -> string;
        include wasi:http/service@0.3.0;
      }
    "#,
    path: "$WIT_PATH",
    world: "vibe:body-read-probe/adapter",
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
        // Still no .collect().await: the reader goes straight to the guest,
        // which is now the thing that drains it.
        let (req_body_rx, _trailers_rx) = Request::consume_body(request, result_rx);
        // An async import's string params are OWNED (String, not &str).
        let raw = handler("POST".to_string(), url, String::new(), req_body_rx).await;

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

echo "[body-read-probe] building the async-import adapter"
(cd "$TMP_DIR" && cargo build --target wasm32-unknown-unknown --release >/dev/null 2>&1) || {
  echo "[body-read-probe] FAILED: adapter did not build -- wit-bindgen no longer accepts an \`async func\` import with a stream<u8> param?" >&2
  (cd "$TMP_DIR" && cargo build --target wasm32-unknown-unknown --release 2>&1 | tail -20) >&2
  exit 1
}

ADAPTER="$OUT_DIR/adapter.component.wasm"
wasm-tools component new \
  "$TMP_DIR/target/wasm32-unknown-unknown/release/vibe_body_read_probe_adapter.wasm" \
  -o "$ADAPTER"
wasm-tools validate --features all "$ADAPTER"
# Both checks match against a CAPTURED string with `case`, no pipeline at all.
# `something | grep -q` is wrong here twice over: grep exits on its first match,
# the writer gets SIGPIPE, and `set -o pipefail` reports that as a failed check
# -- indistinguishable from the assertion actually not holding. The first cut of
# this gate did exactly that and blamed the adapter for a bug in its own plumbing.
ADAPTER_WIT="$(wasm-tools component wit "$ADAPTER")"
case "$ADAPTER_WIT" in
  *'import handler: async func('*) ;;
  *)
    echo "[body-read-probe] FAILED: the adapter's handler import is not an \`async func\`" >&2
    printf '%s\n' "$ADAPTER_WIT" | head -20 >&2
    exit 1 ;;
esac
# The decoded WIT says `async func`; this says the FUNCTYPE carries the async
# flag, which is what `canon lift ... async` is actually checked against.
ADAPTER_DUMP="$(wasm-tools dump "$ADAPTER" 2>/dev/null || true)"
case "$ADAPTER_DUMP" in
  *'ComponentFuncType { async_: true, params: [("method", Primitive(String))'*) ;;
  *)
    echo "[body-read-probe] FAILED: the handler import's functype is not marked async" >&2
    exit 1 ;;
esac
echo "[body-read-probe] adapter imports handler as an async func with a stream<u8> body"

GUEST="$OUT_DIR/guest.wasm"
wasm-tools parse "$PROBE_DIR/guest.wat" -o "$GUEST"
wasm-tools validate --features all "$GUEST"
echo "[body-read-probe] probe guest validates"

COMPOSED="$OUT_DIR/composed.wasm"
wac plug --plug "$GUEST" "$ADAPTER" -o "$COMPOSED"
wasm-tools validate --features all "$COMPOSED"

# `wac plug` leaves an unsatisfiable edge as a promoted ROOT IMPORT rather than
# an error (../http_body_stream/README.md), so assert the composed world, not
# the exit code.
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
  echo "[body-read-probe] FAILED: composed root imports are not exactly the host-provided wasi:http/types edge" >&2
  printf '%s\n' "$COMPOSED_WIT" | head -20 >&2
  exit 1
fi
echo "[body-read-probe] composed: async handler edge connected; only host wasi:http/types remains"

"$WASMTIME_BIN" serve "${WASM_FLAGS[@]}" --addr "$ADDR" "$COMPOSED" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
ready=0
for _ in $(seq 1 40); do
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "[body-read-probe] FAILED: spawned wasmtime exited before accepting requests" >&2
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
  echo "[body-read-probe] FAILED: spawned wasmtime did not become ready at $ADDR" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

RESPONSE_FILE="$TMP_DIR/response.txt"
CODE="$(curl -sS --max-time 10 -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST --data-binary "$BODY_TOKEN" "http://$ADDR/probe" 2>&1 || true)"
OUT="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
if ! kill -0 "$SERVE_PID" 2>/dev/null; then
  echo "[body-read-probe] FAILED: spawned wasmtime exited while serving the probe request" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

if [ "$CODE" != "200" ]; then
  echo "[body-read-probe] FAILED: POST with a body returned '$CODE' (want 200)" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi
# The guest returns its diagnostics as strings so a failure names the broken
# assumption instead of just missing the token.
case "$OUT" in
  *ERR-EVENT*)
    echo "[body-read-probe] FAILED: waitable-set.wait returned a non-STREAM_READ event" >&2; exit 1 ;;
  *ERR-STATUS*)
    echo "[body-read-probe] FAILED: a zero-transfer read reported a code other than the measured CLOSED=1" >&2; exit 1 ;;
  *ERR-OVERRUN*)
    echo "[body-read-probe] FAILED: the guest read 64 bytes without seeing end-of-stream" >&2; exit 1 ;;
esac
if ! printf '%s' "$OUT" | grep -qF "$BODY_TOKEN"; then
  echo "[body-read-probe] FAILED: response body was '$OUT' (want the POSTed '$BODY_TOKEN')" >&2
  cat "$SERVE_LOG" >&2 || true
  exit 1
fi

echo "[body-read-probe] POST body came back through the guest's stream.read loop"
echo "[body-read-probe] PASS: a guest can READ the wasi:http request body from its stream<u8> parameter (#1540)"
