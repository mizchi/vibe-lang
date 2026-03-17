#!/usr/bin/env bash
set -euo pipefail

# Build a WASI HTTP P3 client bridge adapter component.
# This adapter imports wasi:http/client (P3) and exports simplified
# client functions for vibe components to import.
#
# Exports:
#   http-send(method: string, url: string, body: string) -> s64
#   http-response-status(handle: s64) -> s64
#   http-response-body(handle: s64) -> string
#   http-close(handle: s64)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_client_adapter.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_client_adapter.XXXXXX)"

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
name = "vibe_http_p3_client_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.53.1", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
use std::cell::RefCell;
use std::collections::HashMap;

wit_bindgen::generate!({
    inline: r#"
      package vibe:http-client-adapter;

      interface client-bridge {
        http-send: async func(method: string, url: string, body: string) -> s64;
        http-response-status: func(handle: s64) -> s64;
        http-response-body: func(handle: s64) -> string;
        http-close: func(handle: s64);
      }

      world client-bridge-world {
        import wasi:http/types@0.3.0-rc-2026-01-06;
        import wasi:http/client@0.3.0-rc-2026-01-06;
        export client-bridge;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-client-adapter/client-bridge-world",
    generate_all,
});
export!(Component);

/// Tag an integer as vibe tagged int (shift left 2)
fn tag_int(v: i64) -> i64 {
    v << 2
}

/// Untag a vibe tagged int (arithmetic shift right 2)
fn untag_int(v: i64) -> i64 {
    v >> 2
}

/// Stored response data (consumed from P3 response resource)
struct StoredResponse {
    status: u16,
    body: Vec<u8>,
}

thread_local! {
    static RESPONSES: RefCell<HashMap<i64, StoredResponse>> = RefCell::new(HashMap::new());
    static NEXT_HANDLE: RefCell<i64> = RefCell::new(1);
}

fn next_handle() -> i64 {
    NEXT_HANDLE.with(|h| {
        let mut h = h.borrow_mut();
        let id = *h;
        *h += 1;
        id
    })
}

fn store_response(resp: StoredResponse) -> i64 {
    let handle = next_handle();
    RESPONSES.with(|r| {
        r.borrow_mut().insert(handle, resp);
    });
    handle
}

fn parse_method(s: &str) -> wasi::http::types::Method {
    match s.to_uppercase().as_str() {
        "GET" => wasi::http::types::Method::Get,
        "POST" => wasi::http::types::Method::Post,
        "PUT" => wasi::http::types::Method::Put,
        "DELETE" => wasi::http::types::Method::Delete,
        "HEAD" => wasi::http::types::Method::Head,
        "OPTIONS" => wasi::http::types::Method::Options,
        "PATCH" => wasi::http::types::Method::Patch,
        other => wasi::http::types::Method::Other(other.to_string()),
    }
}

fn parse_url(url: &str) -> (Option<wasi::http::types::Scheme>, Option<String>, Option<String>) {
    if let Some(rest) = url.strip_prefix("https://") {
        let (authority, path) = split_authority_path(rest);
        (Some(wasi::http::types::Scheme::Https), Some(authority), Some(path))
    } else if let Some(rest) = url.strip_prefix("http://") {
        let (authority, path) = split_authority_path(rest);
        (Some(wasi::http::types::Scheme::Http), Some(authority), Some(path))
    } else {
        (None, None, Some(url.to_string()))
    }
}

fn split_authority_path(rest: &str) -> (String, String) {
    if let Some(idx) = rest.find('/') {
        (rest[..idx].to_string(), rest[idx..].to_string())
    } else {
        (rest.to_string(), "/".to_string())
    }
}

struct Component;

impl exports::vibe::http_client_adapter::client_bridge::Guest for Component {
    async fn http_send(method: String, url: String, body: String) -> i64 {
        use wasi::http::types::{Fields, Request, Response};

        let (scheme, authority, path) = parse_url(&url);

        let has_body = !body.is_empty();
        let (body_tx, body_rx) = if has_body {
            let (tx, rx) = wit_stream::new();
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };

        let (trailer_tx, trailer_rx) = wit_future::new(|| Ok(None));

        let (request, _transmit) = Request::new(
            Fields::new(),
            body_rx,
            trailer_rx,
            None,
        );

        let method_parsed = parse_method(&method);
        let _ = request.set_method(&method_parsed);

        if let Some(ref p) = path {
            let _ = request.set_path_with_query(Some(p));
        }
        if let Some(ref s) = scheme {
            let _ = request.set_scheme(Some(s));
        }
        if let Some(ref a) = authority {
            let _ = request.set_authority(Some(a));
        }

        if let (Some(mut tx), true) = (body_tx, has_body) {
            drop(trailer_tx);
            wit_bindgen::spawn(async move {
                let remaining = tx.write_all(body.into_bytes()).await;
                assert!(remaining.is_empty());
            });
        } else {
            drop(trailer_tx);
        }

        let result = wasi::http::client::send(request).await;
        match result {
            Ok(response) => {
                let status = response.get_status_code();

                let (res_tx, res_rx) = wit_future::new::<Result<(), wasi::http::types::ErrorCode>>(|| Ok(()));
                drop(res_tx);
                let (mut body_stream, _trailers) = Response::consume_body(response, res_rx);
                let mut body_bytes = Vec::new();
                loop {
                    let buf = vec![0u8; 4096];
                    let (result, data) = body_stream.read(buf).await;
                    body_bytes.extend_from_slice(&data);
                    match result {
                        wit_bindgen::rt::async_support::StreamResult::Complete(n) if n > 0 => continue,
                        _ => break,
                    }
                }

                let handle = store_response(StoredResponse {
                    status,
                    body: body_bytes,
                });
                tag_int(handle)
            }
            Err(_) => {
                tag_int(-1)
            }
        }
    }

    fn http_response_status(handle: i64) -> i64 {
        let handle_id = untag_int(handle);
        RESPONSES.with(|r| {
            let map = r.borrow();
            match map.get(&handle_id) {
                Some(resp) => tag_int(resp.status as i64),
                None => tag_int(0),
            }
        })
    }

    fn http_response_body(handle: i64) -> String {
        let handle_id = untag_int(handle);
        RESPONSES.with(|r| {
            let map = r.borrow();
            match map.get(&handle_id) {
                Some(resp) => String::from_utf8_lossy(&resp.body).into_owned(),
                None => String::new(),
            }
        })
    }

    fn http_close(handle: i64) {
        let handle_id = untag_int(handle);
        RESPONSES.with(|r| {
            r.borrow_mut().remove(&handle_id);
        });
    }
}
EOF

pushd "$TMP_DIR" >/dev/null
cargo build --target wasm32-unknown-unknown --release 2>&1
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_p3_client_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
