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
const tagMask = 3n;
const tagObj = 1n;

const reqHandle = tagInt(11);
const listenerHandle = tagInt(21);
const incomingHandle = tagInt(31);
const expectedRespondStatus = tagInt(204);

const textDecoder = new TextDecoder();

const readU32LE = (mem, pos) => {
  if (pos < 0 || pos + 4 > mem.length) {
    throw new Error(`out of bounds memory read at ${pos}`);
  }
  return (
    mem[pos] |
    (mem[pos + 1] << 8) |
    (mem[pos + 2] << 16) |
    (mem[pos + 3] << 24)
  ) >>> 0;
};

const decodeTaggedString = (instanceRef, tagged) => {
  if (typeof tagged !== 'bigint') {
    throw new Error(`expected tagged string bigint, got ${typeof tagged}`);
  }
  if ((tagged & tagMask) !== tagObj) {
    throw new Error(`expected tagged object string, got tag=${tagged & tagMask}`);
  }
  if (!instanceRef || !(instanceRef.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error('missing exported memory for tagged string decode');
  }
  const ptr = Number(tagged & ~tagMask);
  const mem = new Uint8Array(instanceRef.exports.memory.buffer);
  const ty = readU32LE(mem, ptr);
  if (ty !== 1) {
    throw new Error(`expected obj_string(1), got ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const start = ptr + 8;
  const end = start + len;
  if (end > mem.length) {
    throw new Error(`string range out of bounds: ${start}..${end}`);
  }
  return textDecoder.decode(mem.subarray(start, end));
};

const hostMatchesRule = (host, pattern) => {
  if (pattern === '*') {
    return true;
  }
  if (pattern.startsWith('*.')) {
    const suffix = pattern.slice(1);
    return host.endsWith(suffix);
  }
  return host === pattern;
};

const canConnect = (rules, host, port) =>
  rules.some((rule) => {
    const rulePort = rule.port == null ? null : Number(rule.port);
    return (
      hostMatchesRule(host, rule.host) &&
      (rulePort === null || rulePort === port)
    );
  });

const canListen = (allowedListenPorts, port) =>
  allowedListenPorts.some((entry) => entry === '*' || Number(entry) === port);

const createHost = (options) => {
  const connectRules = options.connectRules ?? [];
  const allowedListenPorts = options.allowedListenPorts ?? [];
  const calls = [];
  const handleKind = new Map();
  let instanceRef = null;

  const ensureConnectAllowed = (urlString) => {
    const url = new URL(urlString);
    const host = url.hostname;
    const portText = url.port;
    const port =
      portText.length > 0
        ? Number(portText)
        : url.protocol === 'https:'
          ? 443
          : url.protocol === 'http:'
            ? 80
            : 0;
    if (!canConnect(connectRules, host, port)) {
      throw new Error(`PermissionDenied: net_connect:${host}:${port}`);
    }
  };

  const ensureListenAllowed = (port) => {
    if (!canListen(allowedListenPorts, port)) {
      throw new Error(`PermissionDenied: net_listen:${port}`);
    }
  };

  const host = {
    http_request: (_method, url, _headers, _body) => {
      const decodedUrl = decodeTaggedString(instanceRef, url);
      ensureConnectAllowed(decodedUrl);
      calls.push('request');
      handleKind.set(reqHandle, 'response');
      return reqHandle;
    },
    http_response_status: (handle) => {
      if (handleKind.get(handle) !== 'response') {
        throw new Error(`unexpected response handle: ${handle}`);
      }
      calls.push('status');
      return tagInt(200);
    },
    http_response_header: (handle, _name) => {
      if (handleKind.get(handle) !== 'response') {
        throw new Error(`unexpected response-header handle: ${handle}`);
      }
      return 0n;
    },
    http_response_body: (handle) => {
      if (handleKind.get(handle) !== 'response') {
        throw new Error(`unexpected response-body handle: ${handle}`);
      }
      return 0n;
    },
    http_close: (handle) => {
      calls.push(`close:${handle.toString()}`);
      handleKind.delete(handle);
      return 0n;
    },
    http_listen: (portValue) => {
      const port = untagInt(portValue);
      ensureListenAllowed(port);
      calls.push('listen');
      handleKind.set(listenerHandle, 'listener');
      return listenerHandle;
    },
    http_accept: (handle) => {
      if (handleKind.get(handle) !== 'listener') {
        throw new Error(`unexpected listener handle: ${handle}`);
      }
      calls.push('accept');
      handleKind.set(incomingHandle, 'incoming');
      return incomingHandle;
    },
    http_request_method: (handle) => {
      if (handleKind.get(handle) !== 'incoming') {
        throw new Error(`unexpected request-method handle: ${handle}`);
      }
      return 0n;
    },
    http_request_url: (handle) => {
      if (handleKind.get(handle) !== 'incoming') {
        throw new Error(`unexpected request-url handle: ${handle}`);
      }
      return 0n;
    },
    http_request_header: (handle, _name) => {
      if (handleKind.get(handle) !== 'incoming') {
        throw new Error(`unexpected request-header handle: ${handle}`);
      }
      return 0n;
    },
    http_request_body: (handle) => {
      if (handleKind.get(handle) !== 'incoming') {
        throw new Error(`unexpected request-body handle: ${handle}`);
      }
      return 0n;
    },
    http_respond: (handle, status, _headers, _body) => {
      if (handleKind.get(handle) !== 'incoming') {
        throw new Error(`unexpected incoming handle: ${handle}`);
      }
      if (status !== expectedRespondStatus) {
        throw new Error(`unexpected response status: ${status}`);
      }
      calls.push('respond');
      return 0n;
    },
  };

  return {
    host,
    calls,
    bindInstance(instance) {
      instanceRef = instance;
    },
  };
};

const expectRunError = (instance, fragment) => {
  try {
    instance.exports.run();
  } catch (err) {
    const message = err && err.message ? err.message : String(err);
    if (message.includes(fragment)) {
      return;
    }
    throw new Error(`expected error including "${fragment}", got "${message}"`);
  }
  throw new Error(`expected run() to fail with "${fragment}"`);
};

(async () => {
  const wasm = fs.readFileSync(wasmPath);

  const denyConnect = createHost({ connectRules: [], allowedListenPorts: [] });
  const denyConnectInst = await WebAssembly.instantiate(wasm, {
    'vibe:http': denyConnect.host,
  });
  denyConnect.bindInstance(denyConnectInst.instance);
  expectRunError(denyConnectInst.instance, 'PermissionDenied: net_connect:example.com:443');

  const denyListen = createHost({
    connectRules: [{ host: 'example.com', port: 443 }],
    allowedListenPorts: [],
  });
  const denyListenInst = await WebAssembly.instantiate(wasm, {
    'vibe:http': denyListen.host,
  });
  denyListen.bindInstance(denyListenInst.instance);
  expectRunError(denyListenInst.instance, 'PermissionDenied: net_listen:8080');

  const allowAll = createHost({
    connectRules: [{ host: 'example.com', port: 443 }],
    allowedListenPorts: [8080],
  });
  const allowAllInst = await WebAssembly.instantiate(wasm, {
    'vibe:http': allowAll.host,
  });
  allowAll.bindInstance(allowAllInst.instance);
  const raw = allowAllInst.instance.exports.run();
  if (typeof raw !== 'bigint') {
    throw new Error(`expected bigint result, got ${typeof raw}`);
  }
  const value = untagInt(raw);
  if (value !== 200) {
    throw new Error(`unexpected run result: ${value}`);
  }
  const expected = [
    'request',
    'status',
    `close:${reqHandle.toString()}`,
    'listen',
    'accept',
    'respond',
    `close:${incomingHandle.toString()}`,
    `close:${listenerHandle.toString()}`,
  ];
  if (
    allowAll.calls.length !== expected.length ||
    allowAll.calls.some((v, i) => v !== expected[i])
  ) {
    throw new Error(
      `unexpected host call order:\nactual=${JSON.stringify(allowAll.calls)}\nexpected=${JSON.stringify(expected)}`,
    );
  }
  console.log(`PASS: http wasm host imports capability+e2e => ${value}`);
})().catch((err) => {
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
EOF
