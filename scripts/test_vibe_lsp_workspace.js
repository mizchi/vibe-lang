#!/usr/bin/env node
// End-to-end test for the LSP server's workspace/symbol + callHierarchy support
// (index-backed; js/vibe/symbol_index.js). Drives the real stdio JSON-RPC server
// over a tiny two-file workspace. Spawns `node js/vibe/lsp_server.js` directly —
// these features are pure-JS (no compiler subprocess), so no vibe build needed.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const SERVER = path.join(__dirname, "..", "js", "vibe", "lsp_server.js");

// --- scratch workspace ------------------------------------------------------
const ws = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-lsp-ws-"));
fs.writeFileSync(path.join(ws, "util.vibe"),
  "let twice = (x: Int) -> Int { x * 2 }\n" +
  "let inc = (x: Int) -> Int { x + 1 }\n" +
  "let combo = (x: Int) -> Int { twice(inc(x)) }\n");
fs.writeFileSync(path.join(ws, "main.vibe"),
  "let run = () -> Int {\n  let a = combo(10)\n  twice(a)\n}\n");

const uri = (p) => "file://" + p;
const srv = spawn(process.execPath, [SERVER], { stdio: ["pipe", "pipe", "inherit"] });

let buf = Buffer.alloc(0);
const pending = new Map();
let idc = 0;
function send(method, params, notify) {
  const id = notify ? undefined : ++idc;
  const m = { jsonrpc: "2.0", method, params };
  if (!notify) m.id = id;
  const b = Buffer.from(JSON.stringify(m), "utf8");
  srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);
  srv.stdin.write(b);
  if (notify) return Promise.resolve();
  return new Promise((r) => pending.set(id, r));
}
srv.stdout.on("data", (c) => {
  buf = Buffer.concat([buf, c]);
  for (;;) {
    const he = buf.indexOf("\r\n\r\n");
    if (he < 0) return;
    const mm = /Content-Length:\s*(\d+)/i.exec(buf.slice(0, he).toString("ascii"));
    if (!mm) { buf = buf.slice(he + 4); continue; }
    const len = +mm[1], st = he + 4;
    if (buf.length < st + len) return;
    const msg = JSON.parse(buf.slice(st, st + len).toString("utf8"));
    buf = buf.slice(st + len);
    if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
  }
});

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log(`ok: ${n}`)) : (fail++, console.error(`FAIL: ${n}${d ? " — " + d : ""}`)); };
const eqset = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

(async () => {
  const init = await send("initialize", { processId: process.pid, rootUri: uri(ws), capabilities: {} });
  ok("advertises workspaceSymbolProvider", init.capabilities.workspaceSymbolProvider === true);
  ok("advertises callHierarchyProvider", init.capabilities.callHierarchyProvider === true);
  await send("initialized", {}, true);

  // workspace/symbol
  const all = await send("workspace/symbol", { query: "" });
  ok("workspace/symbol '' returns all 4 top-level symbols", all.length === 4, `got ${all.length}: ${all.map((s) => s.name).join(",")}`);
  const tw = await send("workspace/symbol", { query: "twice" });
  ok("workspace/symbol 'twice' finds it", tw.some((s) => s.name === "twice"), JSON.stringify(tw.map((s) => s.name)));
  const twHit = tw.find((s) => s.name === "twice");
  ok("result carries cross-file location in util.vibe", twHit && /util\.vibe$/.test(twHit.location.uri.replace(/#.*/, "")), JSON.stringify(twHit && twHit.location.uri));

  // callHierarchy: open main.vibe, prepare on a `twice` usage
  const mainPath = path.join(ws, "main.vibe");
  const mainText = fs.readFileSync(mainPath, "utf8");
  await send("textDocument/didOpen", { textDocument: { uri: uri(mainPath), languageId: "vibe", version: 1, text: mainText } }, true);
  const lines = mainText.split("\n");
  const li = lines.findIndex((l) => l.includes("twice"));
  const ch = lines[li].indexOf("twice") + 1;
  const prep = await send("textDocument/prepareCallHierarchy", { textDocument: { uri: uri(mainPath) }, position: { line: li, character: ch } });
  ok("prepareCallHierarchy returns item for 'twice'", prep && prep[0] && prep[0].name === "twice", JSON.stringify(prep));

  if (prep && prep[0]) {
    const inc = await send("callHierarchy/incomingCalls", { item: prep[0] });
    ok("incomingCalls(twice) = {combo, run} (cross-file)", eqset(inc.map((c) => c.from.name), ["combo", "run"]), JSON.stringify(inc.map((c) => c.from.name)));
    // fromRanges must point at the call site inside the caller (run), not at the
    // callee's definition. In main.vibe `twice(a)` is on the same line as the cursor.
    const runCall = inc.find((c) => c.from.name === "run");
    const fr = runCall && runCall.fromRanges && runCall.fromRanges[0];
    ok("incoming fromRanges point at the call site in the caller", fr && fr.start.line === li, `fromRange=${JSON.stringify(fr)} callLine=${li}`);
  }
  // outgoing of combo (build item via prepare on its def in util.vibe)
  const utilPath = path.join(ws, "util.vibe");
  const utilText = fs.readFileSync(utilPath, "utf8");
  await send("textDocument/didOpen", { textDocument: { uri: uri(utilPath), languageId: "vibe", version: 1, text: utilText } }, true);
  const ulines = utilText.split("\n");
  const uli = ulines.findIndex((l) => l.startsWith("let combo"));
  const uch = ulines[uli].indexOf("combo") + 1;
  const comboPrep = await send("textDocument/prepareCallHierarchy", { textDocument: { uri: uri(utilPath) }, position: { line: uli, character: uch } });
  ok("prepareCallHierarchy returns item for 'combo'", comboPrep && comboPrep[0] && comboPrep[0].name === "combo");
  if (comboPrep && comboPrep[0]) {
    const outg = await send("callHierarchy/outgoingCalls", { item: comboPrep[0] });
    ok("outgoingCalls(combo) = {inc, twice}", eqset(outg.map((c) => c.to.name), ["inc", "twice"]), JSON.stringify(outg.map((c) => c.to.name)));
  }

  // vibe/graph custom request: dependency graph + a query perspective.
  const dg = await send("vibe/graph", { query: "dependencyGraph", level: "module" });
  ok("vibe/graph returns a module dependency graph", dg && Array.isArray(dg.nodes) && Array.isArray(dg.edges), JSON.stringify(dg && Object.keys(dg)));
  const hot = await send("vibe/graph", { query: "hotspots", level: "file", by: "fan-in" });
  ok("vibe/graph hotspots query works", hot && Array.isArray(hot.hotspots), JSON.stringify(hot && Object.keys(hot)));

  await send("shutdown", {});
  await send("exit", {}, true);
  setTimeout(() => {
    try { fs.rmSync(ws, { recursive: true, force: true }); } catch {}
    console.log(`\n[test_vibe_lsp_workspace] ${pass} passed, ${fail} failed`);
    srv.kill();
    process.exit(fail ? 1 : 0);
  }, 150);
})().catch((e) => { console.error(e); srv.kill(); process.exit(2); });
