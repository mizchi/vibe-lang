#!/usr/bin/env node
// Minimal stdio LSP server for vibe (docs/release-roadmap.md テーマ4, MVP 4-1).
//
// Provides push diagnostics by driving the native selfhost compiler
// (`vibe check`) — node here is only JSON-RPC plumbing, the compiler is the
// runner-backed selfhost build. The selfhost frontend does not yet carry source
// spans, so the compiler reports a single formatted diagnostic per file; this
// server heuristically locates the offending symbol in the document text to
// produce a usable range. Once the frontend tracks spans (roadmap foundation),
// this server can consume real ranges without protocol changes.
//
// Configure the compiler via VIBE_BIN (path to the `vibe` launcher; default
// `vibe` on PATH). Editors launch this with `vibe lsp` (or `node lsp_server.js`).

"use strict";
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const VIBE_BIN = process.env.VIBE_BIN || "vibe";

// ---- JSON-RPC over stdio (Content-Length framing) ----------------------
let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = buffer.slice(0, headerEnd).toString("ascii");
    const m = /Content-Length:\s*(\d+)/i.exec(header);
    if (!m) {
      buffer = buffer.slice(headerEnd + 4);
      continue;
    }
    const len = parseInt(m[1], 10);
    const start = headerEnd + 4;
    if (buffer.length < start + len) return;
    const body = buffer.slice(start, start + len).toString("utf8");
    buffer = buffer.slice(start + len);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch {
      continue;
    }
    handle(msg);
  }
});

function send(msg) {
  const json = JSON.stringify(msg);
  const data = Buffer.from(json, "utf8");
  process.stdout.write(`Content-Length: ${data.length}\r\n\r\n`);
  process.stdout.write(data);
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function notify(method, params) {
  send({ jsonrpc: "2.0", method, params });
}

// ---- document store ----------------------------------------------------
const docs = new Map(); // uri -> { text, version }
const pending = new Map(); // uri -> timeout (debounce)

function handle(msg) {
  switch (msg.method) {
    case "initialize":
      reply(msg.id, {
        capabilities: {
          textDocumentSync: 1, // full
          documentSymbolProvider: true,
          definitionProvider: true,
          hoverProvider: true,
          completionProvider: { triggerCharacters: ["."] },
        },
        serverInfo: { name: "vibe-lsp", version: "0.1.0" },
      });
      break;
    case "textDocument/completion": {
      const uri = msg.params.textDocument.uri;
      const doc = docs.get(uri);
      reply(msg.id, doc ? completionItems(doc.text) : []);
      break;
    }
    case "textDocument/documentSymbol": {
      const uri = msg.params.textDocument.uri;
      const doc = docs.get(uri);
      reply(msg.id, doc ? documentSymbols(doc.text) : []);
      break;
    }
    case "textDocument/definition": {
      const uri = msg.params.textDocument.uri;
      const doc = docs.get(uri);
      if (!doc) { reply(msg.id, null); break; }
      const word = wordAt(doc.text, msg.params.position);
      const decl = word ? findDeclaration(doc.text, word) : null;
      reply(msg.id, decl ? { uri, range: decl.selectionRange } : null);
      break;
    }
    case "textDocument/hover": {
      const uri = msg.params.textDocument.uri;
      const doc = docs.get(uri);
      if (!doc) { reply(msg.id, null); break; }
      const word = wordAt(doc.text, msg.params.position);
      const decl = word ? findDeclaration(doc.text, word) : null;
      if (!decl) { reply(msg.id, null); break; }
      reply(msg.id, { contents: { kind: "markdown", value: "```vibe\n" + decl.line.trim() + "\n```" } });
      break;
    }
    case "initialized":
      break;
    case "shutdown":
      reply(msg.id, null);
      break;
    case "exit":
      process.exit(0);
      break;
    case "textDocument/didOpen": {
      const { uri, text } = msg.params.textDocument;
      docs.set(uri, { text, version: msg.params.textDocument.version });
      scheduleCheck(uri);
      break;
    }
    case "textDocument/didChange": {
      const uri = msg.params.textDocument.uri;
      const changes = msg.params.contentChanges;
      if (changes && changes.length) {
        // full sync: last change holds the whole document
        docs.set(uri, { text: changes[changes.length - 1].text, version: msg.params.textDocument.version });
      }
      scheduleCheck(uri);
      break;
    }
    case "textDocument/didSave": {
      const uri = msg.params.textDocument.uri;
      scheduleCheck(uri);
      break;
    }
    case "textDocument/didClose": {
      const uri = msg.params.textDocument.uri;
      docs.delete(uri);
      const t = pending.get(uri);
      if (t) clearTimeout(t);
      pending.delete(uri);
      notify("textDocument/publishDiagnostics", { uri, diagnostics: [] });
      break;
    }
    default:
      if (typeof msg.id !== "undefined" && msg.method) {
        // Unknown request: reply with empty result so clients don't hang.
        reply(msg.id, null);
      }
  }
}

function scheduleCheck(uri) {
  const prev = pending.get(uri);
  if (prev) clearTimeout(prev);
  pending.set(
    uri,
    setTimeout(() => {
      pending.delete(uri);
      runCheck(uri);
    }, 150),
  );
}

function uriToPath(uri) {
  if (uri.startsWith("file://")) {
    return decodeURIComponent(uri.slice("file://".length));
  }
  return uri;
}

// Map a compiler diagnostic message to a document range by locating the most
// likely offending token. Falls back to the first non-empty line.
function locate(text, message) {
  const lines = text.split(/\r?\n/);
  // Exact location: the compiler now prefixes parse diagnostics with
  // `line N:col M:` (source-span foundation). Prefer it when present.
  let lc;
  if ((lc = /\bline\s+(\d+):(\d+):/.exec(message))) {
    const li = Math.max(0, parseInt(lc[1], 10) - 1);
    const co = Math.max(0, parseInt(lc[2], 10) - 1);
    const lineText = lines[li] || "";
    // Tighten the end to the identifier under the column when there is one
    // (the message carries no token length); else highlight to end of line.
    let end = co;
    while (end < lineText.length && /[A-Za-z0-9_]/.test(lineText[end])) end++;
    if (end === co) end = lineText.length > co ? lineText.length : co + 1;
    return {
      start: { line: li, character: co },
      end: { line: li, character: end },
    };
  }
  // Pull a quoted or "unknown name: X" / "... 'op' ..." symbol out of the msg.
  let needle = null;
  let m;
  if ((m = /unknown name:\s*([A-Za-z_][A-Za-z0-9_]*)/.exec(message))) needle = m[1];
  else if ((m = /unbound (?:variable|name)\s*[:]?\s*([A-Za-z_][A-Za-z0-9_]*)/i.exec(message))) needle = m[1];
  else if ((m = /unknown (?:field|ctor|type|name)\s*[:]?\s*([A-Za-z_][A-Za-z0-9_]*)/i.exec(message))) needle = m[1];
  else if ((m = /['"]([^'"]+)['"]/.exec(message))) needle = m[1];

  if (needle) {
    for (let i = 0; i < lines.length; i++) {
      const idx = lines[i].indexOf(needle);
      if (idx >= 0) {
        return {
          start: { line: i, character: idx },
          end: { line: i, character: idx + needle.length },
        };
      }
    }
  }
  // fallback: first non-empty line, whole line.
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().length) {
      return { start: { line: i, character: 0 }, end: { line: i, character: lines[i].length } };
    }
  }
  return { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } };
}

function runCheck(uri) {
  const doc = docs.get(uri);
  if (!doc) return;
  const filePath = uriToPath(uri);
  // Write the in-memory buffer to a temp file next to the real file so relative
  // imports still resolve, then check it.
  const dir = fs.existsSync(path.dirname(filePath)) ? path.dirname(filePath) : os.tmpdir();
  const tmp = path.join(dir, `.vibe-lsp-${process.pid}-${Math.abs(hash(uri))}.vibe`);
  let diagnostics = [];
  try {
    fs.writeFileSync(tmp, doc.text, "utf8");
    const res = spawnSync(VIBE_BIN, ["check", tmp], { encoding: "utf8" });
    const out = `${res.stdout || ""}\n${res.stderr || ""}`;
    if ((res.status && res.status !== 0) || /\berror:/.test(out)) {
      const message = parseMessage(out);
      diagnostics = [
        {
          range: locate(doc.text, message),
          severity: 1, // Error
          source: "vibe",
          message,
        },
      ];
    }
  } catch (e) {
    diagnostics = [
      {
        range: { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } },
        severity: 2,
        source: "vibe-lsp",
        message: `internal: ${e.message}`,
      },
    ];
  } finally {
    try {
      fs.unlinkSync(tmp);
    } catch {}
    try {
      fs.unlinkSync(`${tmp}.diag`);
    } catch {}
  }
  notify("textDocument/publishDiagnostics", { uri, diagnostics });
}

function parseMessage(out) {
  // Prefer the launcher's "error: <file>: <message>" line; strip the temp path.
  const lines = out.split(/\r?\n/);
  for (const line of lines) {
    const m = /^error:\s*(?:[^:]*:\s*)?(.+)$/.exec(line.trim());
    if (m) return m[1].trim();
  }
  for (const line of lines) {
    if (line.trim() && !/^vibe:/.test(line.trim())) return line.trim();
  }
  return "compilation failed";
}

function hash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return h;
}

// Outline via a lightweight scan of top-level declarations. The selfhost
// frontend does not expose spans yet, so symbols are derived from the source
// text; ranges target the declared name. SymbolKind per LSP spec.
const SYMBOL_PATTERNS = [
  { re: /^\s*(?:export\s+)?let\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 13 }, // Variable (functions are let-bound)
  { re: /^\s*(?:export\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 10 }, // Enum
  { re: /^\s*(?:export\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 23 }, // Struct
  { re: /^\s*(?:export\s+)?trait\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 11 }, // Interface
  { re: /^\s*(?:export\s+)?module\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 2 }, // Module
  { re: /^\s*(?:export\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)/, kind: 26 }, // TypeParameter-ish
];

// Identifier under a (line, character) position.
function wordAt(text, pos) {
  const lines = text.split(/\r?\n/);
  const line = lines[pos.line] || "";
  let s = pos.character, e = pos.character;
  const isWord = (c) => /[A-Za-z0-9_]/.test(c);
  while (s > 0 && isWord(line[s - 1])) s--;
  while (e < line.length && isWord(line[e])) e++;
  const w = line.slice(s, e);
  return w.length ? w : null;
}

// Locate the top-level declaration of `name`; returns its line text + range.
function findDeclaration(text, name) {
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const { re } of SYMBOL_PATTERNS) {
      const m = re.exec(line);
      if (m && m[1] === name) {
        const ch = line.indexOf(name, m.index);
        return {
          line,
          selectionRange: {
            start: { line: i, character: ch },
            end: { line: i, character: ch + name.length },
          },
        };
      }
    }
  }
  return null;
}

const VIBE_KEYWORDS = [
  "let", "mut", "export", "import", "enum", "struct", "trait", "module", "type",
  "if", "else", "match", "while", "for", "in", "return", "with", "handle",
  "test", "bench", "true", "false", "throw", "as",
];

// Completion: vibe keywords + the document's declared names. CompletionItemKind:
// 14 = Keyword, 6 = Variable, 3 = Function-ish. Heuristic (no compiler change).
function completionItems(text) {
  const items = VIBE_KEYWORDS.map((k) => ({ label: k, kind: 14 }));
  const seen = new Set(VIBE_KEYWORDS);
  for (const s of documentSymbols(text)) {
    if (!seen.has(s.name)) {
      seen.add(s.name);
      items.push({ label: s.name, kind: 6 });
    }
  }
  return items;
}

function documentSymbols(text) {
  const lines = text.split(/\r?\n/);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const { re, kind } of SYMBOL_PATTERNS) {
      const m = re.exec(line);
      if (m) {
        const name = m[1];
        const ch = line.indexOf(name, m.index);
        const range = {
          start: { line: i, character: 0 },
          end: { line: i, character: line.length },
        };
        const selectionRange = {
          start: { line: i, character: ch },
          end: { line: i, character: ch + name.length },
        };
        out.push({ name, kind, range, selectionRange });
        break;
      }
    }
  }
  return out;
}
