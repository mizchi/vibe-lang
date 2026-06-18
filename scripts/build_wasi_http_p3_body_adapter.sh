#!/usr/bin/env bash
set -euo pipefail

# Build a WASI P3 HTTP adapter whose vibe handler returns the response BODY.
#
# Unlike build_wasi_http_p3_adapter.sh (handler -> status code), here the vibe
# handler controls the response body:
#   export let handler = (method: String, url: String) -> String { "..." }
# The adapter serves it with HTTP 200.
#
# Serve with (wasmtime 45):
#   wasmtime serve -Sp3 -Shttp -W exceptions=y -W concurrency-support=y \
#     -W component-model-async=y -W component-model-async-stackful=y <component.wasm>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_body_adapter.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_body_adapter.XXXXXX)"

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
name = "vibe_http_p3_body_adapter"
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
      package vibe:http-body-adapter;

      world adapter {
        /// vibe handler: (method, url) -> response body string.
        import handler: func(method: string, url: string) -> string;
        include wasi:http/service@0.3.0-rc-2026-03-15;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-body-adapter/adapter",
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

        // The vibe handler produces the response body.
        let body_text = handler(&method, &url);

        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(Fields::new(), Some(body_rx), body_result_rx);
        resp.set_status_code(200)
            .map_err(|_| ErrorCode::InternalError(None))?;
        drop(body_result_tx);

        wit_bindgen::spawn(async move {
            let remaining = body_tx.write_all(body_text.into_bytes()).await;
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
  target/wasm32-unknown-unknown/release/vibe_http_p3_body_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
