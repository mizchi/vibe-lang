#!/usr/bin/env bash
set -euo pipefail

# Build the comprehensive WASI P3 HTTP adapter: the vibe handler sees the full
# request (method, url, request headers, request body) and returns a full
# HTTP response (status + response headers + body).
#
#   export let handler =
#     (method: String, url: String, headers: String, body: String) -> String {
#       // headers: request headers as "name: value\n" lines
#       // return: "STATUS\n<Header: value lines>\n\n<body>"  (headers optional)
#     }
#
# Serve with (wasmtime 46, ratified wasi:http@0.3.0, #821):
#   wasmtime serve -Sp3 -Shttp <component.wasm>
# (component-model-async is default-on in wasmtime 46; the wasmtime 45 RC
# flag set `-W exceptions=y -W concurrency-support=y -W component-model-async=y
# -W component-model-async-stackful=y` is accepted as harmless no-ops on 46
# but is no longer required.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_full_adapter.component.wasm}"
# #1540: with VIBE_HTTP_ADAPTER_ASYNC_HANDLER=1 the handler import is declared
# `async func` and awaited. This is not a style switch: a handler that suspends
# must be async-LIFTED, and `canon lift ... async` validates only against an
# async functype -- which is the one the ADAPTER declares. A sync import here
# makes an async-lifted handler unpluggable
# (tools/wasip3_component_probe/http_body_read/README.md).
ASYNC_HANDLER="${VIBE_HTTP_ADAPTER_ASYNC_HANDLER:-0}"
# #1540 scope 4: with VIBE_HTTP_ADAPTER_BODY_STREAM=1 the body is handed to the
# handler as a `stream<u8>` instead of being collected into a String first --
# the whole point of the issue: the handler sees the first byte before the last
# one has arrived. Implies the async import (reading the stream suspends).
BODY_STREAM="${VIBE_HTTP_ADAPTER_BODY_STREAM:-0}"
if [ "$BODY_STREAM" = "1" ]; then
  ASYNC_HANDLER=1
  HANDLER_IMPORT_DECL="import handler: async func(method: string, url: string, headers: string, body: stream<u8>) -> string;"
  # `req_body_rx` goes straight through -- no .collect().await anywhere.
  HANDLER_CALL="handler(method, url, req_headers, req_body_rx).await"
  # The collected body binding is unused in this mode, and Rust warns; bind it
  # to the reader instead so there is exactly one place the body can come from.
  BODY_BINDING="let req_body_rx = { let (rx, _trailers_rx) = Request::consume_body(request, result_rx); rx };"
elif [ "$ASYNC_HANDLER" = "1" ]; then
  HANDLER_IMPORT_DECL="import handler: async func(method: string, url: string, headers: string, body: string) -> string;"
  # An async import owns its string params (String, not &str) and returns a
  # future.
  HANDLER_CALL="handler(method, url, req_headers, req_body).await"
else
  HANDLER_IMPORT_DECL="import handler: func(method: string, url: string, headers: string, body: string) -> string;"
  HANDLER_CALL="handler(&method, &url, &req_headers, &req_body)"
fi
if [ "$BODY_STREAM" != "1" ]; then
  BODY_BINDING="let (req_body_rx, _trailers_rx) = Request::consume_body(request, result_rx);
        let req_body = String::from_utf8_lossy(&req_body_rx.collect().await).into_owned();"
fi
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_full_adapter.XXXXXX)"

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
name = "vibe_http_p3_full_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

# WIT source for the wasi:http p3 world: prefer the in-repo vendored copy
# (lib/@vibe/wasi/wit/p3, from crates.io wasmtime-wasi-http 46.0.1, ratified
# wasi:http@0.3.0 — see its VENDOR.md) so the gate is self-contained; fall
# back to the deps/wasmtime submodule checkout for developers who track
# wasmtime HEAD (#821).
WIT_PATH="$PROJECT_ROOT/lib/@vibe/wasi/wit/p3"
if [ ! -f "$WIT_PATH/world.wit" ]; then
  WIT_PATH="$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit"
fi

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:http-full-adapter;

      world adapter {
        /// vibe handler: (method, url, request-headers, request-body) ->
        ///   "STATUS\n<Header: value lines>\n\n<body>".
        /// request-headers are passed as "name: value\n" lines.
        $HANDLER_IMPORT_DECL
        include wasi:http/service@0.3.0;
      }
    "#,
    path: "$WIT_PATH",
    world: "vibe:http-full-adapter/adapter",
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

        // Serialize request headers as "name: value\n" lines (borrow before consume).
        let req_headers = request
            .get_headers()
            .copy_all()
            .into_iter()
            .map(|(n, v)| format!("{}: {}", n, String::from_utf8_lossy(&v)))
            .collect::<Vec<_>>()
            .join("\n");

        let (_, result_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
        $BODY_BINDING

        // The vibe handler returns "STATUS\n<headers>\n\n<body>" (headers optional).
        let raw = $HANDLER_CALL;
        let (status_line, rest) = raw.split_once('\n').unwrap_or(("200", raw.as_str()));
        let status_code = status_line.trim().parse::<u16>().unwrap_or(200);
        let (headers_block, body) = rest.split_once("\n\n").unwrap_or(("", rest));
        let resp_text = body.to_string();

        let fields = Fields::new();
        for hline in headers_block.lines() {
            if let Some((name, value)) = hline.split_once(':') {
                let _ = fields.append(&name.trim().to_string(), &value.trim().as_bytes().to_vec());
            }
        }

        let (mut body_tx, body_rx) = wit_stream::new();
        let (body_result_tx, body_result_rx) = wit_future::new(|| Ok(None));
        let (resp, _transmit) = Response::new(fields, Some(body_rx), body_result_rx);
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
  target/wasm32-unknown-unknown/release/vibe_http_p3_full_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
