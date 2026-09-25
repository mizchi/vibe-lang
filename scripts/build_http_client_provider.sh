#!/usr/bin/env bash
set -euo pipefail

# #2066: build the CLIENT half of a `wasi:http/service` composition.
#
# A vibe serve handler that awaits a `from_wit` response binding imports the
# binding's interface -- `example:http-lite/client@1.0.0`'s
# `fetch(url: string)`, whose response record carries `status: s32` and
# `body: stream<u8>` from the package's `types` interface. This component
# exports exactly that pair and implements `fetch` over `wasi:http/client`:
# it sends a GET for the URL and hands the response's own body stream through,
# so the handler reads the upstream body as it arrives rather than after it
# was collected. Plugged into the handler component with `wac plug`, the
# result is one component that exports `handler` and imports `wasi:http/client`
# -- the service world's two directions.
#
# The export is the binding's WIT exactly as written --
# `fetch: async func(url: string) -> response` -- since the composer lowers a
# WIT async import as a subtask rather than as `-> future<response>` (#3131).
#
# A transport failure (no connection, a URL this parser does not accept) traps
# the provider, which fails the request rather than inventing a status.
#
# MODE `handler` builds the MIDDLEWARE variant: `fetch` hands the request to an
# imported `wasi:http/handler` -- the next component in the chain -- instead of
# sending it over the network, so the plugged result imports and exports
# `handler`, the `wasi:http/middleware` world's two directions.
#
# usage: build_http_client_provider.sh <out.component.wasm> [client|handler]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:?usage: build_http_client_provider.sh <out.component.wasm> [client|handler]}"
MODE="${2:-client}"
case "$MODE" in
  client)
    SEND_IMPORT="import wasi:http/client@0.3.0;"
    SEND_CALL="wasi::http::client::send(request)" ;;
  handler)
    SEND_IMPORT="import wasi:http/handler@0.3.0;"
    SEND_CALL="wasi::http::handler::handle(request)" ;;
  *)
    echo "build_http_client_provider.sh: MODE must be client or handler, got: $MODE" >&2
    exit 1 ;;
esac
case "$OUT_PATH" in
  /*) ;;
  *) OUT_PATH="$PWD/$OUT_PATH" ;;
esac
TMP_DIR="$(mktemp -d /tmp/vibe_http_client_provider.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for c in cargo wasm-tools; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c" >&2; exit 1; }
done
if [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

WIT_PATH="$PROJECT_ROOT/lib/@vibe/wasi/wit/p3"
if [ ! -f "$WIT_PATH/world.wit" ]; then
  WIT_PATH="$PROJECT_ROOT/deps/wasmtime/crates/wasi-http/src/p3/wit"
fi

mkdir -p "$TMP_DIR/src" "$TMP_DIR/wit/deps/example-http-lite" "$(dirname "$OUT_PATH")"
cp -R "$WIT_PATH/deps/." "$TMP_DIR/wit/deps/"
# The binding's own WIT, not a restatement of it: what the handler was derived
# from is exactly what this provider implements.
cp "$PROJECT_ROOT/fixtures/wit_response_request/client.wit" "$TMP_DIR/wit/deps/example-http-lite/client.wit"
cat >"$TMP_DIR/wit/world.wit" <<EOF
package vibe:http-client-provider;

world provider {
  import wasi:http/types@0.3.0;
  $SEND_IMPORT
  export example:http-lite/types@1.0.0;
  export example:http-lite/client@1.0.0;
}
EOF

cat >"$TMP_DIR/Cargo.toml" <<'EOF'
[package]
name = "vibe_http_client_provider"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wit-bindgen = { version = "0.54.0", default-features = false, features = ["macros", "realloc", "bitflags", "async", "async-spawn"] }
EOF

cat >"$TMP_DIR/src/lib.rs" <<'EOF'
wit_bindgen::generate!({
    path: "wit",
    world: "vibe:http-client-provider/provider",
    generate_all,
});

use exports::example::http_lite::client::Guest;
use exports::example::http_lite::types::Response as LiteResponse;
use wasi::http::types::{ErrorCode, Fields, Method, Request, Response, Scheme};

struct Component;

/// `http://host[:port][/path][?query][#fragment]` -> (scheme, authority,
/// path-with-query). The authority ends at the first `/` or `?`; a query with
/// no path keeps its query under `/`, and a fragment is never sent.
fn split_url(url: &str) -> (Scheme, String, String) {
    let (scheme, rest) = if let Some(r) = url.strip_prefix("http://") {
        (Scheme::Http, r)
    } else if let Some(r) = url.strip_prefix("https://") {
        (Scheme::Https, r)
    } else {
        panic!("http client provider: unsupported URL (want http:// or https://): {url}");
    };
    let rest = rest.split('#').next().unwrap_or("");
    let end = rest.find(|c| c == '/' || c == '?').unwrap_or(rest.len());
    let (authority, target) = rest.split_at(end);
    if authority.is_empty() {
        panic!("http client provider: URL has no host: {url}");
    }
    let path = if target.is_empty() {
        "/".to_string()
    } else if target.starts_with('?') {
        format!("/{target}")
    } else {
        target.to_string()
    };
    (scheme, authority.to_string(), path)
}

async fn get(url: String) -> LiteResponse {
    let (scheme, authority, path) = split_url(&url);
    let (_trailers_tx, trailers_rx) = wit_future::new::<Result<Option<Fields>, ErrorCode>>(|| Ok(None));
    let (request, _sent) = Request::new(Fields::new(), None, trailers_rx, None);
    request.set_method(&Method::Get).expect("http client provider: set-method");
    request.set_scheme(Some(&scheme)).expect("http client provider: set-scheme");
    request.set_authority(Some(&authority)).expect("http client provider: set-authority");
    request.set_path_with_query(Some(&path)).expect("http client provider: set-path-with-query");
    let response: Response = match __SEND_CALL__.await {
        Ok(r) => r,
        Err(e) => panic!("http client provider: GET {url}: {e:?}"),
    };
    let status = i32::from(response.get_status_code());
    let (_done_tx, done_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
    let (body, _trailers) = Response::consume_body(response, done_rx);
    LiteResponse { status, body }
}

impl Guest for Component {
    async fn fetch(url: String) -> LiteResponse {
        get(url).await
    }
}


export!(Component);
EOF

# The one line that differs between the two modes.
sed "s|__SEND_CALL__|$SEND_CALL|" "$TMP_DIR/src/lib.rs" >"$TMP_DIR/src/lib.rs.tmp"
mv "$TMP_DIR/src/lib.rs.tmp" "$TMP_DIR/src/lib.rs"

pushd "$TMP_DIR" >/dev/null
cargo build --quiet --target wasm32-unknown-unknown --release
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_client_provider.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
