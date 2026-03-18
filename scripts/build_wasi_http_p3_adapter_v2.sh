#!/usr/bin/env bash
set -euo pipefail

# Build WASI HTTP P3 adapter v2: handler returns string response.
# Protocol: "STATUS_CODE\n\nBODY" or "STATUS_CODE\nHeader: Value\n\nBODY"
# Examples:
#   "200\n\nhello world"
#   "200\ncontent-type: application/json\n\n{\"ok\":true}"
#   "404\n\nnot found"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_adapter_v2.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_adapter_v2.XXXXXX)"

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
name = "vibe_http_p3_adapter_v2"
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
      package vibe:http-adapter-v2;

      world adapter {
        /// vibe handler: (method, url) -> "STATUS\nHeaders\n\nBody"
        import handler: func(method: string, url: string) -> string;
        include wasi:http/service@0.3.0-rc-2026-02-09;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-adapter-v2/adapter",
    pub_export_macro: true,
    generate_all,
});

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Request, Response};

struct Component;

/// Parse vibe handler response string.
/// Format: "STATUS_CODE\nHeader: Value\n...\n\nBODY"
/// Minimal: "200\n\nhello" (status + empty headers + body)
fn parse_response(raw: &str) -> (u16, Vec<(String, String)>, String) {
    let mut status: u16 = 200;
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut body = String::new();

    if let Some(sep_pos) = raw.find("\n\n") {
        let head = &raw[..sep_pos];
        body = raw[sep_pos + 2..].to_string();

        let mut lines = head.lines();
        if let Some(status_line) = lines.next() {
            if let Ok(code) = status_line.trim().parse::<u16>() {
                status = code;
            }
        }
        for line in lines {
            if let Some(colon_pos) = line.find(':') {
                let key = line[..colon_pos].trim().to_string();
                let value = line[colon_pos + 1..].trim().to_string();
                headers.push((key, value));
            }
        }
    } else {
        if let Ok(code) = raw.trim().parse::<u16>() {
            status = code;
        } else {
            body = raw.to_string();
        }
    }

    (status, headers, body)
}

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

        let raw_response = handler(&method, &url);
        let (status_code, custom_headers, body_text) = parse_response(&raw_response);

        let resp_headers = Fields::new();
        for (key, value) in &custom_headers {
            let _ = resp_headers.append(key, value.as_bytes());
        }
        if !custom_headers.iter().any(|(k, _)| k.eq_ignore_ascii_case("content-type")) {
            let _ = resp_headers.append("content-type", b"text/plain; charset=utf-8");
        }

        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(resp_headers, Some(body_rx), body_result_rx);
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
  target/wasm32-unknown-unknown/release/vibe_http_p3_adapter_v2.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
