#!/usr/bin/env bash
set -euo pipefail

# Build a WASI P3 HTTP adapter whose vibe handler returns BOTH status and body.
#
#   export let handler = (method: String, url: String, body: String) -> (Int, String) {
#     if String::equals(url, "/health") { (200, "ok") } else { (404, "not found") }
#   }
#
# The adapter reads the request body, calls the handler, and serves the returned
# (status, body). Enables real routing (200/404/...) with response content.
#
# Serve with (wasmtime 45):
#   wasmtime serve -Sp3 -Shttp -W exceptions=y -W concurrency-support=y \
#     -W component-model-async=y -W component-model-async-stackful=y <component.wasm>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_status_body_adapter.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_status_body_adapter.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
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

if [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

mkdir -p "$TMP_DIR/src"
mkdir -p "$(dirname "$OUT_PATH")"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_http_p3_status_body_adapter"
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
      package vibe:http-status-body-adapter;

      world adapter {
        /// vibe handler: (method, url, request-body) -> "STATUS\nBODY".
        /// The first line of the returned string is the HTTP status code; the
        /// remainder is the response body. (A single string is used because the
        /// host --compose-p3 string-lift supports only single-value returns, not
        /// tuples — see docs/spec/wasi-p3-async.md §4.1.)
        import handler: func(method: string, url: string, body: string) -> string;
        include wasi:http/service@0.3.0-rc-2026-03-15;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-status-body-adapter/adapter",
    pub_export_macro: true,
    generate_all,
});

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Request, Response};

struct Component;

impl Guest for Component {
    async fn handle(request: Request) -> Result<Response, ErrorCode> {
        let method = match request.get_method() {
            wasi::http::types::Method::Get => "GET".to_string(),
            wasi::http::types::Method::Post => "POST".to_string(),
            wasi::http::types::Method::Put => "PUT".to_string(),
            wasi::http::types::Method::Delete => "DELETE".to_string(),
            wasi::http::types::Method::Head => "HEAD".to_string(),
            wasi::http::types::Method::Options => "OPTIONS".to_string(),
            wasi::http::types::Method::Patch => "PATCH".to_string(),
            wasi::http::types::Method::Other(m) => m,
            _ => "UNKNOWN".to_string(),
        };
        let url = request.get_path_with_query().unwrap_or_else(|| "/".to_string());

        let (_, result_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
        let (req_body_rx, _trailers_rx) = Request::consume_body(request, result_rx);
        let req_body_bytes = req_body_rx.collect().await;
        let req_body = String::from_utf8_lossy(&req_body_bytes).into_owned();

        // The vibe handler returns "STATUS\nBODY"; split the leading status line.
        let raw = handler(&method, &url, &req_body);
        let (status_code, resp_text) = match raw.split_once('\n') {
            Some((s, rest)) => (s.trim().parse::<u16>().unwrap_or(200), rest.to_string()),
            None => (200u16, raw),
        };

        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(Fields::new(), Some(body_rx), body_result_rx);
        resp.set_status_code(status_code)
            .map_err(|_| ErrorCode::InternalError(None))?;
        drop(body_result_tx);

        wit_bindgen::spawn(async move {
            let remaining = body_tx.write_all(resp_text.into_bytes()).await;
            assert!(remaining.is_empty());
        });

        Ok(resp)
    }
}

export!(Component);
EOF

pushd "$TMP_DIR" >/dev/null
cargo build --target wasm32-unknown-unknown --release
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_p3_status_body_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
