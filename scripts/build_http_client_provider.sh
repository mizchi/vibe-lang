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
# The export spells `fetch` the way the composer imports it: an async function
# whose result is `future<response>` (the run lane's response ABI, which
# viberun's `VIBE_ASYNC_RESPONSES` provider implements too). That is not the
# source WIT's `-> response`; #3131 tracks lowering the import as written.
#
# A transport failure (no connection, a URL this parser does not accept) traps
# the provider, which fails the request rather than inventing a status.
#
# usage: build_http_client_provider.sh <out.component.wasm>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_PATH="${1:?usage: build_http_client_provider.sh <out.component.wasm>}"
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
cat >"$TMP_DIR/wit/deps/example-http-lite/client.wit" <<'EOF'
package example:http-lite@1.0.0;

interface types {
  record response {
    status: s32,
    body: stream<u8>,
  }
}

interface client {
  use types.{response};

  fetch: async func(url: string) -> future<response>;
}
EOF
cat >"$TMP_DIR/wit/world.wit" <<'EOF'
package vibe:http-client-provider;

world provider {
  import wasi:http/types@0.3.0;
  import wasi:http/client@0.3.0;
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

/// `http://host[:port]/path?query` -> (scheme, authority, path-with-query).
fn split_url(url: &str) -> (Scheme, String, String) {
    let (scheme, rest) = if let Some(r) = url.strip_prefix("http://") {
        (Scheme::Http, r)
    } else if let Some(r) = url.strip_prefix("https://") {
        (Scheme::Https, r)
    } else {
        panic!("http client provider: unsupported URL (want http:// or https://): {url}");
    };
    match rest.find('/') {
        Some(i) => (scheme, rest[..i].to_string(), rest[i..].to_string()),
        None => (scheme, rest.to_string(), "/".to_string()),
    }
}

async fn get(url: String) -> LiteResponse {
    let (scheme, authority, path) = split_url(&url);
    let (_trailers_tx, trailers_rx) = wit_future::new::<Result<Option<Fields>, ErrorCode>>(|| Ok(None));
    let (request, _sent) = Request::new(Fields::new(), None, trailers_rx, None);
    request.set_method(&Method::Get).expect("http client provider: set-method");
    request.set_scheme(Some(&scheme)).expect("http client provider: set-scheme");
    request.set_authority(Some(&authority)).expect("http client provider: set-authority");
    request.set_path_with_query(Some(&path)).expect("http client provider: set-path-with-query");
    let response: Response = match wasi::http::client::send(request).await {
        Ok(r) => r,
        Err(e) => panic!("http client provider: GET {url}: {e:?}"),
    };
    let status = i32::from(response.get_status_code());
    let (_done_tx, done_rx) = wit_future::new::<Result<(), ErrorCode>>(|| Ok(()));
    let (body, _trailers) = Response::consume_body(response, done_rx);
    LiteResponse { status, body }
}

impl Guest for Component {
    async fn fetch(url: String) -> wit_bindgen::FutureReader<LiteResponse> {
        let (tx, rx) = wit_future::new::<LiteResponse>(|| unreachable!("http client provider: the response future was dropped unwritten"));
        wit_bindgen::spawn(async move {
            let resp = get(url).await;
            let _ = tx.write(resp).await;
        });
        rx
    }
}


export!(Component);
EOF

pushd "$TMP_DIR" >/dev/null
cargo build --quiet --target wasm32-unknown-unknown --release
wasm-tools component new \
  target/wasm32-unknown-unknown/release/vibe_http_client_provider.wasm \
  -o "$OUT_PATH"
wasm-tools validate --features all "$OUT_PATH"
popd >/dev/null

echo "wrote $OUT_PATH"
