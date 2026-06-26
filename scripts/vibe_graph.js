#!/usr/bin/env node
// Export a vibe workspace's symbol + call graph as JSON for macro-level
// visualization (à la mizchi/sprawlens). Builds the in-process incremental
// index (js/vibe/symbol_index.js) over a directory tree and emits:
//
//   {
//     root,
//     nodes: [{ id, name, kind, file, module, size }],   // symbols, sized by span
//     edges: [{ from, to, weight }],                      // call edges (resolved)
//     modules: [{ name, symbols, files }],                // rollups for zoom-out
//     stats: { files, symbols, edges, ms }
//   }
//
// `kind` is the LSP SymbolKind. A renderer can lay nodes out by module, size
// area by `size`, and bundle `edges` as the call graph; `modules` gives the
// zoomed-out plane. Import edges are available per file via the index but are
// emitted here only as intra-call edges to keep the default output call-focused.
//
// Usage:
//   node scripts/vibe_graph.js [rootDir] [--out file.json] [--functions-only]
"use strict";
const fs = require("fs");
const path = require("path");
const { SymbolIndex, KIND } = require(path.join(__dirname, "..", "js", "vibe", "symbol_index.js"));

const args = process.argv.slice(2);
let root = null, out = null, functionsOnly = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--out") out = args[++i];
  else if (args[i] === "--functions-only") functionsOnly = true;
  else if (!args[i].startsWith("--")) root = args[i];
}
root = path.resolve(root || process.cwd());

function walk(dir, acc) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== "node_modules" && e.name !== ".git" && e.name !== "target") walk(p, acc); }
    else if (e.isFile() && p.endsWith(".vibe")) acc.push(p);
  }
  return acc;
}

const t0 = Number(process.hrtime.bigint()) / 1e6;
const idx = new SymbolIndex();
const files = walk(root, []);
for (const f of files) { try { idx.update(f, fs.readFileSync(f, "utf8")); } catch {} }

let g = idx.graph({ root });
if (functionsOnly) {
  const fnIds = new Set(g.nodes.filter((n) => n.kind === KIND.Function).map((n) => n.id));
  g.nodes = g.nodes.filter((n) => fnIds.has(n.id));
  g.edges = g.edges.filter((e) => fnIds.has(e.from) && fnIds.has(e.to));
}

// Module rollups (zoom-out plane): symbol + file counts per module.
const modMap = new Map();
for (const n of g.nodes) {
  const m = modMap.get(n.module) || { name: n.module, symbols: 0, files: new Set() };
  m.symbols++; m.files.add(n.file); modMap.set(n.module, m);
}
const modules = [...modMap.values()].map((m) => ({ name: m.name, symbols: m.symbols, files: m.files.size }))
  .sort((a, b) => b.symbols - a.symbols);

const result = {
  root: g.root,
  nodes: g.nodes,
  edges: g.edges,
  modules,
  stats: { files: idx.fileCount, symbols: g.nodes.length, edges: g.edges.length, ms: +(Number(process.hrtime.bigint()) / 1e6 - t0).toFixed(1) },
};

const json = JSON.stringify(result, null, out ? 0 : 2);
if (out) {
  fs.writeFileSync(out, json);
  process.stderr.write(`vibe graph -> ${out}: ${result.stats.symbols} nodes, ${result.stats.edges} edges, ${result.stats.files} files in ${result.stats.ms} ms\n`);
} else {
  process.stdout.write(json + "\n");
}
