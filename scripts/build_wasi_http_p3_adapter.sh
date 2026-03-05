#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_adapter.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_adapter.XXXXXX)"

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

if [ -x "/Users/mz/.cargo/bin/cargo" ]; then
  export PATH="/Users/mz/.cargo/bin:$PATH"
fi

mkdir -p "$TMP_DIR/src"
mkdir -p "$(dirname "$OUT_PATH")"

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_http_p3_adapter"
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

      world adapter {
        /// vibe handler: (method, url) -> status code (tagged i64).
        import handler: func(method: string, url: string) -> s64;
        include wasi:http/service@0.3.0-rc-2026-01-06;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-adapter/adapter",
    pub_export_macro: true,
    generate_all,
});

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Request, Response};

struct Component;

impl Guest for Component {
    async fn handle(request: Request) -> Result<Response, ErrorCode> {
        // Extract method and url from request
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

        // Call vibe handler with method and url (returns tagged status code)
        let status_tagged = handler(&method, &url);
        let status_code = (status_tagged >> 2) as u16; // untag int

        // Build P3 response with body
        let body_text = format!("method={} url={} status={}", method, url, status_code);
        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(Fields::new(), Some(body_rx), body_result_rx);
        resp.set_status_code(status_code)
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
  target/wasm32-unknown-unknown/release/vibe_http_p3_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
echo "note: wasmtime serve で async p3 component を起動するには少なくとも次が必要"
echo "  wasmtime serve -Sp3 -W component-model-async=y -W component-model-async-builtins=y <component.wasm>"
