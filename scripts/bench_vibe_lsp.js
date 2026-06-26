#!/usr/bin/env node
// Benchmark for the vibe LSP workspace symbol / call-hierarchy index
// (js/vibe/symbol_index.js).
//
// Establishes the perf case for the in-process index: the LSP server answers
// queries by spawning a `vibe` subprocess (each loads the wasm compiler), which
// is fine for one hover but ~0.5s PER FILE — so a naive `workspace/symbol` or
// `callHierarchy` that needs every file's symbols would take minutes. The index
// extracts the same information directly from source in-process.
//
// Measures, over the repo's .vibe corpus:
//   1. cold index build (extract all files)
//   2. no-op re-scan (every file unchanged -> incremental hash skip)
//   3. single-file edit re-index (the steady-state editor hot path)
//   4. workspace/symbol query latency
//   5. call-hierarchy (incoming/outgoing) query latency
//   6. baseline: `vibe symbols` subprocess cost on a sample, extrapolated
//
// Usage: node scripts/bench_vibe_lsp.js [rootDir] [--baseline]
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { SymbolIndex } = require(path.join(__dirname, "..", "js", "vibe", "symbol_index.js"));

const ROOT = path.resolve(process.argv[2] && !process.argv[2].startsWith("--") ? process.argv[2] : path.join(__dirname, "..", "vibe"));
const WANT_BASELINE = process.argv.includes("--baseline");

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== "node_modules" && e.name !== ".git") walk(p, out); }
    else if (e.isFile() && p.endsWith(".vibe")) out.push(p);
  }
  return out;
}

function ms(t) { return `${t.toFixed(1)} ms`; }
function now() { return Number(process.hrtime.bigint()) / 1e6; }

function main() {
  console.log(`== vibe LSP index benchmark ==`);
  console.log(`root: ${ROOT}`);
  const files = walk(ROOT, []);
  const texts = new Map();
  let bytes = 0;
  for (const f of files) { const t = fs.readFileSync(f, "utf8"); texts.set(f, t); bytes += t.length; }
  console.log(`corpus: ${files.length} files, ${(bytes / 1e6).toFixed(2)} MB\n`);

  // 1. cold build
  let t0 = now();
  const idx = new SymbolIndex();
  for (const f of files) idx.update(f, texts.get(f));
  const buildMs = now() - t0;
  console.log(`1. cold index build      : ${ms(buildMs)}  (${(files.length / (buildMs / 1000)).toFixed(0)} files/s, ${(bytes / 1e6 / (buildMs / 1000)).toFixed(1)} MB/s)`);
  console.log(`   indexed               : ${idx.symbolCount} symbols across ${idx.fileCount} files`);

  // 2. no-op re-scan (all unchanged -> hash skip)
  t0 = now();
  let changed = 0;
  for (const f of files) if (idx.update(f, texts.get(f))) changed++;
  const rescanMs = now() - t0;
  console.log(`2. no-op re-scan          : ${ms(rescanMs)}  (${changed} re-extracted, ${idx.stats().skips} hash-skipped)`);

  // 3. single-file edit re-index (median over the 20 largest files)
  const bySize = [...files].sort((a, b) => texts.get(b).length - texts.get(a).length).slice(0, 20);
  const editTimes = [];
  for (const f of bySize) {
    const orig = texts.get(f);
    const edited = orig + "\nlet __bench_marker = () -> Int { 0 }\n";
    let s = now(); idx.update(f, edited); editTimes.push(now() - s);
    idx.update(f, orig); // restore
  }
  editTimes.sort((a, b) => a - b);
  console.log(`3. single-file edit       : ${ms(editTimes[editTimes.length >> 1])} median, ${ms(editTimes[editTimes.length - 1])} max  (20 largest files)`);

  // 4. workspace/symbol latency
  const queries = ["check", "parse", "type", "compile", "emit", "Index", "resolve", "x"];
  let qt = 0, qn = 0, hits = 0;
  for (let r = 0; r < 50; r++) for (const q of queries) {
    const s = now(); const res = idx.workspaceSymbols(q, 100); qt += now() - s; qn++; hits += res.length;
  }
  console.log(`4. workspace/symbol query : ${ms(qt / qn)} avg over ${qn} queries  (${(hits / qn).toFixed(0)} results avg)`);

  // 5. call hierarchy latency — pick a frequently-defined name
  const sample = idx.workspaceSymbols("", 1)[0];
  const probes = ["check_program", "extractFile", "update", sample ? sample.name : "main"];
  let ht = 0, hn = 0;
  for (let r = 0; r < 50; r++) for (const name of probes) {
    let s = now(); idx.incomingCalls(name); idx.outgoingCalls(name); ht += now() - s; hn++;
  }
  console.log(`5. call-hierarchy query   : ${ms(ht / hn)} avg (incoming+outgoing) over ${hn} probes`);

  // graph export size
  const s = now(); const g = idx.graph({ root: path.join(__dirname, "..") }); const gms = now() - s;
  console.log(`   graph() export         : ${ms(gms)}  (${g.nodes.length} nodes, ${g.edges.length} edges)`);

  // 6. baseline subprocess comparison
  if (WANT_BASELINE) {
    const VIBE = process.env.VIBE_BIN || "vibe";
    // Sample EVENLY across the size distribution (small + medium + large) so the
    // mean per-file cost is representative, not skewed by the giant adapter.
    const sorted = [...files].sort((a, b) => texts.get(a).length - texts.get(b).length);
    const sample = [];
    const N = 12;
    for (let i = 0; i < N; i++) sample.push(sorted[Math.floor((i + 0.5) * sorted.length / N)]);
    let st = now();
    for (const f of sample) spawnSync(VIBE, ["symbols", f], { encoding: "utf8", timeout: 30000 });
    const perFile = (now() - st) / sample.length;
    console.log(`\n6. baseline \`vibe symbols\` : ${ms(perFile)}/file mean (subprocess), ${sample.length} files spread across sizes`);
    console.log(`   extrapolated workspace : ${(perFile * files.length / 1000).toFixed(1)} s for ${files.length} files (one spawn each)`);
    console.log(`   index speedup          : ${(perFile * files.length / buildMs).toFixed(0)}x faster (cold build) for full-workspace symbols`);
  } else {
    console.log(`\n(pass --baseline to measure the \`vibe symbols\` subprocess cost for comparison)`);
  }
}

main();
