#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TMP_DIR="$(mktemp -d "/tmp/vibe_http_wasm_host_imports.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "node is required" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

SRC_PATH="$TMP_DIR/http_host_imports_probe.vibe"
WASM_PATH="$TMP_DIR/http_host_imports_probe.wasm"

cat >"$SRC_PATH" <<'EOF'
let run = () -> Int with {Net} {
  let req = http_request("GET", "https://example.com", "", "")
  let status = http_response_status(req)
  http_close(req)
  let listener = http_listen(8080)
  let incoming = http_accept(listener)
  http_respond(incoming, 204, "", "")
  http_close(incoming)
  http_close(listener)
  status
}
run()
EOF

moon run --target native src/cmd/vibe -- compile --wasm --http-host-imports "$SRC_PATH" -o "$WASM_PATH"

WASM_PATH="$WASM_PATH" node <<'EOF'
const fs = require('fs');

const wasmPath = process.env.WASM_PATH;
if (!wasmPath) {
  console.error('WASM_PATH is required');
  process.exit(1);
}

const tagInt = (n) => BigInt(n) << 2n;
const untagInt = (n) => Number(n >> 2n);

const reqHandle = tagInt(11);
const listenerHandle = tagInt(21);
const incomingHandle = tagInt(31);
const expectedRespondStatus = tagInt(204);

const calls = [];

const host = {
  http_request: (_method, _url, _headers, _body) => {
    calls.push('request');
    return reqHandle;
  },
  http_response_status: (handle) => {
    if (handle !== reqHandle) {
      throw new Error(`unexpected response handle: ${handle}`);
    }
    calls.push('status');
    return tagInt(200);
  },
  http_response_header: () => 0n,
  http_response_body: () => 0n,
  http_close: (handle) => {
    calls.push(`close:${handle.toString()}`);
    return 0n;
  },
  http_listen: (_addr) => {
    calls.push('listen');
    return listenerHandle;
  },
  http_accept: (handle) => {
    if (handle !== listenerHandle) {
      throw new Error(`unexpected listener handle: ${handle}`);
    }
    calls.push('accept');
    return incomingHandle;
  },
  http_request_method: () => 0n,
  http_request_url: () => 0n,
  http_request_header: () => 0n,
  http_request_body: () => 0n,
  http_respond: (handle, status, _headers, _body) => {
    if (handle !== incomingHandle) {
      throw new Error(`unexpected incoming handle: ${handle}`);
    }
    if (status !== expectedRespondStatus) {
      throw new Error(`unexpected response status: ${status}`);
    }
    calls.push('respond');
    return 0n;
  },
};

(async () => {
  const wasm = fs.readFileSync(wasmPath);
  const { instance } = await WebAssembly.instantiate(wasm, { 'vibe:http': host });
  const raw = instance.exports.run();
  if (typeof raw !== 'bigint') {
    throw new Error(`expected bigint result, got ${typeof raw}`);
  }
  const value = untagInt(raw);
  const expected = ['request', 'status', `close:${reqHandle.toString()}`, 'listen', 'accept', 'respond', `close:${incomingHandle.toString()}`, `close:${listenerHandle.toString()}`];
  if (value !== 200) {
    throw new Error(`unexpected run result: ${value}`);
  }
  if (calls.length !== expected.length || calls.some((v, i) => v !== expected[i])) {
    throw new Error(`unexpected host call order:\nactual=${JSON.stringify(calls)}\nexpected=${JSON.stringify(expected)}`);
  }
  console.log(`PASS: http wasm host imports e2e => ${value}`);
})().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
EOF
