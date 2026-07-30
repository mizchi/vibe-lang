#!/usr/bin/env node
"use strict";

// Worker-thread half of the Node dev runner's Socket::tcp_* support (mirrors
// runtime/viberun's blocking std::net::TcpStream host imports). Node has no
// synchronous TCP client, but the guest's `vibe.tcp_*` imports are called
// through wasmtime/wasm's synchronous func_wrap ABI and must return before
// the guest instruction stream continues -- so the main thread blocks on
// Atomics.wait() while this worker does the real async net.Socket work and
// wakes it back up via Atomics.notify() once a result (or error) is ready.
// See wasm_vibe_host_runner.js's tcp_connect/tcp_read/tcp_write/tcp_close
// for the main-thread side of this handshake.

const net = require("node:net");
const { workerData } = require("node:worker_threads");

const port = workerData.port;
const sockets = new Map();
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

port.on("message", (msg) => {
  const signal = msg.signal;
  if (msg.op === "connect") {
    const sock = net.createConnection({ host: msg.host, port: msg.tcpPort });
    let settled = false;
    sock.once("connect", () => {
      settled = true;
      const handle = nextHandle;
      nextHandle += 1;
      sockets.set(handle, sock);
      respond(msg, signal, handle);
    });
    sock.once("error", (e) => {
      if (!settled) {
        settled = true;
        fail(msg, signal, e);
      }
    });
    return;
  }
  const sock = sockets.get(msg.handle);
  if (msg.op === "close") {
    if (sock) {
      sock.destroy();
      sockets.delete(msg.handle);
    }
    respond(msg, signal, 0);
    return;
  }
  if (!sock) {
    fail(msg, signal, new Error(`vibe tcp_${msg.op}: unknown handle`));
    return;
  }
  if (msg.op === "write") {
    sock.write(Buffer.from(msg.data, "utf8"), (err) => {
      if (err) fail(msg, signal, err);
      else respond(msg, signal, 0);
    });
    return;
  }
  if (msg.op === "read") {
    // Paused-mode `.read()` (no 'data' listener ever attached, so the
    // stream never switches to flowing mode) -- lets us serve a chunk
    // already buffered immediately, or wait for exactly the next one.
    // `.read(n)` demands AT LEAST n bytes be buffered (returns null until
    // then, even if some data already arrived) -- real socket reads (and
    // runtime/viberun's std::net::TcpStream::read) return as soon as ANY data
    // is available, up to the requested cap, so read only what's already
    // buffered (capped at maxBytes) instead of demanding the full amount.
    const tryRead = () => {
      const available = sock.readableLength;
      const chunk = available > 0 ? sock.read(Math.min(msg.maxBytes, available)) : null;
      if (chunk !== null) {
        sock.removeListener("readable", tryRead);
        sock.removeListener("end", onEnd);
        sock.removeListener("error", onError);
        respond(msg, signal, chunk.toString("utf8"));
      }
    };
    const onEnd = () => {
      sock.removeListener("readable", tryRead);
      sock.removeListener("end", onEnd);
      sock.removeListener("error", onError);
      respond(msg, signal, "");
    };
    const onError = (e) => {
      sock.removeListener("readable", tryRead);
      sock.removeListener("end", onEnd);
      sock.removeListener("error", onError);
      fail(msg, signal, e);
    };
    if (msg.maxBytes <= 0 || sock.readableEnded) {
      respond(msg, signal, "");
      return;
    }
    sock.on("readable", tryRead);
    sock.once("end", onEnd);
    sock.once("error", onError);
    tryRead();
    return;
  }
  fail(msg, signal, new Error(`vibe tcp worker: unknown op '${msg.op}'`));
});
