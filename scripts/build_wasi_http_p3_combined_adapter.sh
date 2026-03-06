#!/usr/bin/env bash
set -euo pipefail

# Build a combined WASI HTTP P3 adapter component.
# This adapter handles BOTH incoming handler requests AND outgoing client requests.
#
# Handler direction:
#   import handler(method, url) -> s64 from vibe
#   export wasi:http/handler to host
#
# Client direction:
#   import wasi:http/client from host
#   When vibe handler returns negative status (-1 tagged), adapter makes outgoing request
#
# Protocol:
#   handler returns >= 0 → direct response with that status code
#   handler returns -1   → proxy: make GET to backend URL (from X-Proxy-Target header or /proxy path)
#   handler returns -2   → proxy with POST method

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:-$PROJECT_ROOT/_build/http_adapter/vibe_http_p3_combined_adapter.component.wasm}"
TMP_DIR="$(mktemp -d /tmp/vibe_http_p3_combined_adapter.XXXXXX)"

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
name = "vibe_http_p3_combined_adapter"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.53.1", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
futures = { version = "0.3", default-features = false, features = ["alloc"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<EOF
wit_bindgen::generate!({
    inline: r#"
      package vibe:http-combined-adapter;

      world adapter {
        /// vibe handler: (method, url) -> tagged status code.
        /// Positive = direct response. -1 = proxy GET, -2 = proxy POST.
        import handler: func(method: string, url: string) -> s64;
        import wasi:http/types@0.3.0-rc-2026-01-06;
        import wasi:http/client@0.3.0-rc-2026-01-06;
        include wasi:http/service@0.3.0-rc-2026-01-06;
      }
    "#,
    path: "$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit",
    world: "vibe:http-combined-adapter/adapter",
    generate_all,
});
export!(Component);

use exports::wasi::http::handler::Guest;
use wasi::http::types::{ErrorCode, Fields, Method, Request, Response, Scheme};

struct Component;

fn method_to_string(m: &Method) -> String {
    match m {
        Method::Get => "GET".to_string(),
        Method::Post => "POST".to_string(),
        Method::Put => "PUT".to_string(),
        Method::Delete => "DELETE".to_string(),
        Method::Head => "HEAD".to_string(),
        Method::Options => "OPTIONS".to_string(),
        Method::Patch => "PATCH".to_string(),
        Method::Other(m) => m.clone(),
        _ => "UNKNOWN".to_string(),
    }
}

fn build_response(status_code: u16, body_text: String) -> Result<Response, ErrorCode> {
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

async fn make_client_request(method: Method, target_url: &str) -> Result<(u16, Vec<u8>), ErrorCode> {
    use futures::join;

    let (scheme, authority, path) = parse_url(target_url);

    let (contents_tx, contents_rx) = wit_stream::new::<u8>();
    let (trailers_tx, trailers_rx) = wit_future::new(|| Ok(None));
    let (request, transmit) = Request::new(Fields::new(), Some(contents_rx), trailers_rx, None);
    let _ = request.set_method(&method);
    if let Some(ref p) = path {
        let _ = request.set_path_with_query(Some(p));
    }
    if let Some(ref s) = scheme {
        let _ = request.set_scheme(Some(s));
    }
    if let Some(ref a) = authority {
        let _ = request.set_authority(Some(a));
    }

    let (transmit_result, handle_result) = join!(
        async {
            // No request body to send — close streams
            drop(contents_tx);
            _ = trailers_tx.write(Ok(None)).await;
            transmit.await
        },
        async {
            let response = wasi::http::client::send(request).await
                .map_err(|e| e)?;

            let status = response.get_status_code();

            let (_, result_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
            let (body_rx, _trailers_rx) = Response::consume_body(response, result_rx);
            let body = body_rx.collect().await;

            Ok::<_, ErrorCode>((status, body))
        },
    );

    let _ = transmit_result;
    handle_result
}

fn parse_url(url: &str) -> (Option<Scheme>, Option<String>, Option<String>) {
    if let Some(rest) = url.strip_prefix("https://") {
        let (authority, path) = split_authority_path(rest);
        (Some(Scheme::Https), Some(authority), Some(path))
    } else if let Some(rest) = url.strip_prefix("http://") {
        let (authority, path) = split_authority_path(rest);
        (Some(Scheme::Http), Some(authority), Some(path))
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

impl Guest for Component {
    async fn handle(request: Request) -> Result<Response, ErrorCode> {
        let method = request.get_method();
        let method_str = method_to_string(&method);
        let url = request.get_path_with_query().unwrap_or_else(|| "/".to_string());

        // Call vibe handler to get routing decision
        let status_tagged = handler(&method_str, &url);
        let status_code = status_tagged >> 2; // untag int

        if status_code >= 0 {
            // Direct response
            let body_text = format!("method={} url={} status={}", method_str, url, status_code);
            build_response(status_code as u16, body_text)
        } else if status_code == -1 {
            // Proxy GET: extract target URL from query or use default backend
            let target = extract_proxy_target(&url);
            match make_client_request(Method::Get, &target).await {
                Ok((client_status, client_body)) => {
                    let body_str = String::from_utf8_lossy(&client_body).into_owned();
                    build_response(client_status, format!("proxied: {}", body_str))
                }
                Err(e) => {
                    build_response(502, format!("proxy error: {:?}", e))
                }
            }
        } else if status_code == -2 {
            // Proxy POST
            let target = extract_proxy_target(&url);
            match make_client_request(Method::Post, &target).await {
                Ok((client_status, client_body)) => {
                    let body_str = String::from_utf8_lossy(&client_body).into_owned();
                    build_response(client_status, format!("proxied: {}", body_str))
                }
                Err(e) => {
                    build_response(502, format!("proxy error: {:?}", e))
                }
            }
        } else {
            build_response(500, "unknown handler code".to_string())
        }
    }
}

fn extract_proxy_target(url: &str) -> String {
    // Check for ?target=<url> parameter
    if let Some(idx) = url.find("?target=") {
        return url[idx + 8..].to_string();
    }
    // Default backend
    "http://127.0.0.1:18794/backend".to_string()
}
EOF

pushd "$TMP_DIR" >/dev/null
cargo build --target wasm32-unknown-unknown --release 2>&1
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_p3_combined_adapter.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
