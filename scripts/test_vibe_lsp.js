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

  // syntax-error document -> diagnostic located at the failing line (the
  // compiler now emits `line N:col M:`, which the server maps to a range).
  const synUri = "file:///tmp/vibe-lsp-test-syntax.vibe";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: synUri, languageId: "vibe", version: 1, text: "export let a = 1\nexport let bad = = 5\n" } } });
  const synDiag = await waitFor(isDiag(synUri));
  check("syntax error yields a diagnostic", synDiag.params.diagnostics.length >= 1);
  if (synDiag.params.diagnostics.length) {
    check("syntax diagnostic located on line 2", synDiag.params.diagnostics[0].range.start.line === 1);
  }

  // error recovery: two independent syntax errors -> TWO diagnostics on
  // different lines (the recovering parser collects past the first error).
  const multiUri = "file:///tmp/vibe-lsp-test-multi.vibe";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: multiUri, languageId: "vibe", version: 1, text: "export let a = = 1\nexport let ok = 2\nexport let b = = 3\n" } } });
  const multiDiag = await waitFor(isDiag(multiUri));
  const multiLines = new Set((multiDiag.params.diagnostics || []).map((d) => d.range.start.line));
  check("error recovery yields diagnostics on >=2 lines", multiLines.size >= 2 && multiLines.has(0) && multiLines.has(2));

  // good document -> expect empty diagnostics
  const goodUri = "file:///tmp/vibe-lsp-test-good.vibe";
  const goodText = "export enum Color { Red; Green }\nexport let helper = (x: Int) -> Int { x * 2 }\nexport let main = () -> Int { helper(21) }\n";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri: goodUri, languageId: "vibe", version: 1, text: goodText } } });
  const goodDiag = await waitFor(isDiag(goodUri));
  check("good doc yields 0 diagnostics", goodDiag.params.diagnostics.length === 0);

  // documentSymbol -> outline of top-level declarations
  send({ jsonrpc: "2.0", id: 3, method: "textDocument/documentSymbol", params: { textDocument: { uri: goodUri } } });
  const sym = await waitFor((m) => m.id === 3);
  const names = (sym.result || []).map((s) => s.name);
  check("documentSymbol lists declarations", names.includes("Color") && names.includes("helper") && names.includes("main"));

  // definition: cursor on `helper` in main's body -> jumps to helper's decl (line 1)
  const callLine = goodText.split(/\r?\n/)[2]; // "export let main = () -> Int { helper(21) }"
  const helperCol = callLine.indexOf("helper");
  send({ jsonrpc: "2.0", id: 4, method: "textDocument/definition", params: { textDocument: { uri: goodUri }, position: { line: 2, character: helperCol + 1 } } });
  const def = await waitFor((m) => m.id === 4);
  check("definition jumps to declaration line", def.result && def.result.range && def.result.range.start.line === 1);

  // hover: shows the declaration of the symbol under the cursor
  send({ jsonrpc: "2.0", id: 5, method: "textDocument/hover", params: { textDocument: { uri: goodUri }, position: { line: 2, character: helperCol + 1 } } });
  const hov = await waitFor((m) => m.id === 5);
  check("hover shows declaration", hov.result && /helper/.test(JSON.stringify(hov.result.contents)));
  // typed hover: the compiler's inferred type for `helper` ((Int) -> Int) is
  // surfaced via `vibe type-at`, not just the declaration text.
  const hovVal = hov.result ? JSON.stringify(hov.result.contents) : "";
  check("hover shows inferred type", /Int/.test(hovVal) && /->|-&gt;/.test(hovVal));

  // references: all occurrences of the symbol under the cursor
  send({ jsonrpc: "2.0", id: 7, method: "textDocument/references", params: { textDocument: { uri: goodUri }, position: { line: 2, character: helperCol + 1 }, context: { includeDeclaration: true } } });
  const refs = await waitFor((m) => m.id === 7);
  // `helper` appears twice in goodText (declaration line 1 + call line 2)
  check("references finds both helper occurrences", (refs.result || []).length === 2);

  // rename: produce a workspace edit replacing all occurrences of the symbol
  send({ jsonrpc: "2.0", id: 8, method: "textDocument/rename", params: { textDocument: { uri: goodUri }, position: { line: 2, character: helperCol + 1 }, newName: "doubler" } });
  const ren = await waitFor((m) => m.id === 8);
  const edits = ren.result && ren.result.changes && ren.result.changes[goodUri];
  check("rename edits both occurrences to new name", Array.isArray(edits) && edits.length === 2 && edits.every((e) => e.newText === "doubler"));

  // signatureHelp: cursor inside `helper(...)` on line 2 -> show helper's
  // inferred signature ((Int) -> Int) via vibe type-at.
  send({ jsonrpc: "2.0", id: 9, method: "textDocument/signatureHelp", params: { textDocument: { uri: goodUri }, position: { line: 2, character: helperCol + 7 } } });
  const sig = await waitFor((m) => m.id === 9);
  const sigLabel = sig.result && sig.result.signatures && sig.result.signatures[0] && sig.result.signatures[0].label;
  check("signatureHelp shows inferred signature", !!sigLabel && /helper/.test(sigLabel) && /Int/.test(sigLabel));

  // completion: keywords + document declarations
  send({ jsonrpc: "2.0", id: 6, method: "textDocument/completion", params: { textDocument: { uri: goodUri }, position: { line: 2, character: 0 } } });
  const comp = await waitFor((m) => m.id === 6);
  const labels = (comp.result || []).map((c) => c.label);
  check("completion offers keywords + symbols", labels.includes("let") && labels.includes("helper") && labels.includes("Color"));

  send({ jsonrpc: "2.0", id: 2, method: "shutdown", params: {} });
  await waitFor((m) => m.id === 2);
  send({ jsonrpc: "2.0", method: "exit", params: {} });

  console.log(`[lsp-test] ${pass} passed, ${fail} failed`);
  srv.kill();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => { console.error(e); srv.kill(); process.exit(1); });
