#!/usr/bin/env node
// Drive js/vibe/lsp_server.js over stdio and assert it publishes diagnostics
// for a bad file and clears them for a good one. Uses VIBE_BIN from the env
// (the installed launcher) for the actual compile.
"use strict";
const { spawn } = require("child_process");
const path = require("path");

const serverPath = path.join(__dirname, "..", "js", "vibe", "lsp_server.js");
const srv = spawn("node", [serverPath], { stdio: ["pipe", "pipe", "inherit"], env: process.env });

let buf = Buffer.alloc(0);
const inbox = [];
const waiters = [];
srv.stdout.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const he = buf.indexOf("\r\n\r\n");
    if (he < 0) return;
    const m = /Content-Length:\s*(\d+)/i.exec(buf.slice(0, he).toString());
    if (!m) { buf = buf.slice(he + 4); continue; }
    const len = parseInt(m[1], 10);
    if (buf.length < he + 4 + len) return;
    const body = buf.slice(he + 4, he + 4 + len).toString("utf8");
    buf = buf.slice(he + 4 + len);
    const msg = JSON.parse(body);
    if (waiters.length) waiters.shift()(msg); else inbox.push(msg);
  }
});

function send(msg) {
  const data = Buffer.from(JSON.stringify(msg), "utf8");
  srv.stdin.write(`Content-Length: ${data.length}\r\n\r\n`);
  srv.stdin.write(data);
}

function waitFor(pred, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const found = inbox.findIndex(pred);
    if (found >= 0) return resolve(inbox.splice(found, 1)[0]);
    const to = setTimeout(() => reject(new Error("timeout waiting for message")), timeoutMs);
    const tick = (msg) => {
      if (pred(msg)) { clearTimeout(to); resolve(msg); }
      else waiters.push(tick);
    };
    waiters.push(tick);
  });
}

const isDiag = (uri) => (m) => m.method === "textDocument/publishDiagnostics" && m.params.uri === uri;

(async () => {
  let pass = 0, fail = 0;
  const check = (desc, cond) => { if (cond) { console.log(`ok: ${desc}`); pass++; } else { console.error(`FAIL: ${desc}`); fail++; } };

  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } });
  const init = await waitFor((m) => m.id === 1);
  check("initialize returns capabilities", init.result && init.result.capabilities);

  send({ jsonrpc: "2.0", method: "initialized", params: {} });

  // bad document -> expect a diagnostic mentioning the unknown name
  const badUri = "file:///tmp/vibe-lsp-test-bad.vibe";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: badUri, languageId: "vibe", version: 1, text: "export let main = () -> Int { zzz }\n" } } });
  const badDiag = await waitFor(isDiag(badUri));
  check("bad doc yields >=1 diagnostic", badDiag.params.diagnostics.length >= 1);
  if (badDiag.params.diagnostics.length) {
    const d = badDiag.params.diagnostics[0];
    check("diagnostic message mentions zzz", /zzz/.test(d.message));
    const badText = "export let main = () -> Int { zzz }\n";
    const line = badText.split(/\r?\n/)[d.range.start.line] || "";
    const slice = line.slice(d.range.start.character, d.range.end.character);
    check("diagnostic range targets the zzz token", slice === "zzz");
  }

  // good document -> expect empty diagnostics
  const goodUri = "file:///tmp/vibe-lsp-test-good.vibe";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: goodUri, languageId: "vibe", version: 1, text: "export let main = () -> Int { 40 + 2 }\n" } } });
  const goodDiag = await waitFor(isDiag(goodUri));
  check("good doc yields 0 diagnostics", goodDiag.params.diagnostics.length === 0);

  send({ jsonrpc: "2.0", id: 2, method: "shutdown", params: {} });
  await waitFor((m) => m.id === 2);
  send({ jsonrpc: "2.0", method: "exit", params: {} });

  console.log(`[lsp-test] ${pass} passed, ${fail} failed`);
  srv.kill();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error(e); srv.kill(); process.exit(1); });
