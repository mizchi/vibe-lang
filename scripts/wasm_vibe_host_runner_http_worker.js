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

// Redirect statuses that carry a `Location` header worth following. 301/302
// legacy-downgrade a non-GET/HEAD method+body to a bodiless GET (matching
// curl/fetch/ureq's default behavior); 303 always downgrades to GET; 307/308
// preserve the original method and body. MAX_REDIRECTS mirrors common HTTP
// client defaults (fetch, ureq) -- a bound exists purely to avoid hanging on
// a redirect loop, not to match any single library's exact count.
const MAX_REDIRECTS = 10;

function performRequest(method, url, headers, body, redirectsLeft, onDone, onError) {
  const client = url.protocol === "https:" ? https : http;
  const req = client.request(url, { method, headers }, (res) => {
    const status = res.statusCode;
    const location = res.headers.location;
    if (status >= 300 && status < 400 && location && redirectsLeft > 0) {
      res.resume(); // discard body, we're not returning this response
      let nextUrl;
      try {
        nextUrl = new URL(location, url);
      } catch (e) {
        onError(e);
        return;
      }
      const downgrade = status === 303 || ((status === 301 || status === 302) && method !== "GET" && method !== "HEAD");
      const nextMethod = downgrade ? "GET" : method;
      const nextBody = downgrade ? undefined : body;
      const nextHeaders = { ...headers };
      if (downgrade) {
        delete nextHeaders["content-length"];
        delete nextHeaders["Content-Length"];
      }
      performRequest(nextMethod, nextUrl, nextHeaders, nextBody, redirectsLeft - 1, onDone, onError);
      return;
    }
    const chunks = [];
    res.on("data", (chunk) => chunks.push(chunk));
    res.on("end", () => onDone(res, Buffer.concat(chunks)));
    res.on("error", onError);
  });
  req.on("error", onError);
  if (body) {
    req.write(body);
  }
  req.end();
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
    performRequest(
      msg.method,
      url,
      parseHeaders(msg.headers),
      msg.body,
      MAX_REDIRECTS,
      (res, bodyBuf) => {
        const handle = nextHandle;
        nextHandle += 1;
        // Node already lowercases header names on `res.headers`, matching
        // the case-insensitive lookup response_header() needs.
        responses.set(handle, {
          status: res.statusCode,
          headers: res.headers,
          body: bodyBuf.toString("utf8"),
        });
        respond(msg, signal, handle);
      },
      (e) => fail(msg, signal, e),
    );
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
