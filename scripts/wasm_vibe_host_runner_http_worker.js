#!/usr/bin/env node
"use strict";

// Worker-thread half of the Node dev runner's Http::request/response_*/close
// support (mirrors runtime/viberun's blocking ureq-based host imports, #1226).
// Node has no synchronous HTTP client, but the guest's `vibe.http_*` imports
// are called through wasmtime/wasm's synchronous func_wrap ABI and must
// return before the guest instruction stream continues -- so the main thread
// blocks on Atomics.wait() while this worker does the real async http/https
// request and wakes it back up via Atomics.notify() once a result (or error)
// is ready. Same bridge shape as wasm_vibe_host_runner_tcp_worker.js; see
// wasm_vibe_host_runner.js's http_request/response_status/response_header/
// response_body/close for the main-thread side of this handshake.

const http = require("node:http");
const https = require("node:https");
const { workerData } = require("node:worker_threads");

const port = workerData.port;
const responses = new Map();
let nextHandle = 1;

function respond(msg, signal, result) {
  port.postMessage({ id: msg.id, result });
  Atomics.store(signal, 0, 1);
  Atomics.notify(signal, 0);
}

function fail(msg, signal, err) {
  port.postMessage({ id: msg.id, error: String((err && err.message) || err) });
  Atomics.store(signal, 0, 1);
  Atomics.notify(signal, 0);
}

// Wire format is `"name: value\n"`-joined (lib/@vibe/http/high_level.vibe's
// `headers_to_wire`) -- same convention low-level callers of `request()`
// already produce by hand.
function parseHeaders(wire) {
  const headers = {};
  for (const line of wire.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const idx = trimmed.indexOf(":");
    if (idx < 0) continue;
    headers[trimmed.slice(0, idx).trim()] = trimmed.slice(idx + 1).trim();
  }
  return headers;
}

port.on("message", (msg) => {
  const signal = msg.signal;
  if (msg.op === "request") {
    let url;
    try {
      url = new URL(msg.url);
    } catch (e) {
      fail(msg, signal, e);
      return;
    }
    const client = url.protocol === "https:" ? https : http;
    const req = client.request(url, { method: msg.method, headers: parseHeaders(msg.headers) }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const handle = nextHandle;
        nextHandle += 1;
        // Node already lowercases header names on `res.headers`, matching
        // the case-insensitive lookup response_header() needs.
        responses.set(handle, {
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        });
        respond(msg, signal, handle);
      });
      res.on("error", (e) => fail(msg, signal, e));
    });
    req.on("error", (e) => fail(msg, signal, e));
    if (msg.body) {
      req.write(msg.body);
    }
    req.end();
    return;
  }
  if (msg.op === "close") {
    responses.delete(msg.handle);
    respond(msg, signal, 0);
    return;
  }
  const entry = responses.get(msg.handle);
  if (!entry) {
    fail(msg, signal, new Error(`vibe http_${msg.op}: unknown handle`));
    return;
  }
  if (msg.op === "status") {
    respond(msg, signal, entry.status);
    return;
  }
  if (msg.op === "header") {
    const value = entry.headers[msg.name.toLowerCase()];
    respond(msg, signal, Array.isArray(value) ? value.join(", ") : value || "");
    return;
  }
  if (msg.op === "body") {
    respond(msg, signal, entry.body);
    return;
  }
  fail(msg, signal, new Error(`vibe http worker: unknown op '${msg.op}'`));
});
