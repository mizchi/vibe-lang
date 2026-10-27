#!/usr/bin/env node
// wasm_func_sizes.mjs — per-function code-size attribution (#1107 Phase 3).
//
// Prints one line per defined function, sorted by body size (largest first):
//   <size-bytes> <func-index> <name-or-?>
// followed by a summary (code section total, name coverage, top-N share).
// Names come from the "name" custom section, so run this on a build made with
// VIBE_WASM_NAMES=1 (release executables are stripped by default, ADR-0077):
//   VIBE_WASM_NAMES=1 bash scripts/generations.sh build --out-dir /tmp/attr_gen
//   node scripts/wasm_func_sizes.mjs /tmp/attr_gen/stage2.wasm --top 40
// `--json` emits all defined functions for source-bound diagnostic consumers.
//
// `--prefix-rollup` aggregates by name prefix (text before the last "__" or
// first "_exp_"), which maps well onto vibe codegen provenance: user functions
// keep their source names, lambdas are `<owner>__lambda_N`, and generated
// namespace exports are `<pkg>_exp_lib__...`.

import { readFileSync } from "node:fs";

function uleb(buf, p) {
  let r = 0n, s = 0n, b;
  do {
    if (p >= buf.length || s >= 35n) throw new Error("truncated or oversized u32 LEB128");
    b = buf[p++]; r |= BigInt(b & 0x7f) << s; s += 7n;
  } while (b & 0x80);
  if (r > 0xffffffffn) throw new Error("oversized u32 LEB128");
  return [Number(r), p];
}

const args = process.argv.slice(2);
let file = null, top = 30, rollup = false, asJson = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--top") top = parseInt(args[++i], 10);
  else if (args[i] === "--prefix-rollup") rollup = true;
  else if (args[i] === "--json") asJson = true;
  else file = args[i];
}
if (!file) {
  console.error("usage: node scripts/wasm_func_sizes.mjs <module.wasm> [--top N] [--prefix-rollup] [--json]");
  process.exit(2);
}

const b = readFileSync(file);
if (!b.subarray(0, 8).equals(Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]))) {
  throw new Error("expected a core Wasm version-1 module");
}
function limits(q) {
  let flags; [flags, q] = uleb(b, q);
  // Refuse unhandled memory64/shared/custom-page forms rather than shifting
  // every following function name onto the wrong definition.
  if (flags !== 0 && flags !== 1) throw new Error(`unsupported import limits flags ${flags}`);
  [, q] = uleb(b, q);
  if (flags === 1) [, q] = uleb(b, q);
  return q;
}
let p = 8;
let numImportedFuncs = 0;
let codeOff = -1, codeSize = 0;
const names = new Map();
while (p < b.length) {
  const sid = b[p++];
  let sz; [sz, p] = uleb(b, p);
  const end = p + sz;
  if (end > b.length) throw new Error("truncated Wasm section");
  if (sid === 2) {
    let cnt; let q = p;
    [cnt, q] = uleb(b, q);
    for (let i = 0; i < cnt; i++) {
      let ml; [ml, q] = uleb(b, q); q += ml;
      let fl; [fl, q] = uleb(b, q); q += fl;
      const kind = b[q++];
      if (kind === 0) { numImportedFuncs++; [, q] = uleb(b, q); }
      else if (kind === 1) {
        const ref = b[q++];
        if (ref !== 0x70 && ref !== 0x6f) throw new Error("unsupported imported table reference type");
        q = limits(q);
      }
      else if (kind === 2) { q = limits(q); }
      else if (kind === 3) {
        if (b[q] === 0x63 || b[q] === 0x64) throw new Error("unsupported imported typed-reference global");
        q += 2;
      }
      else if (kind === 4) {
        let attribute; [attribute, q] = uleb(b, q);
        if (attribute !== 0) throw new Error("unsupported imported tag attribute");
        [, q] = uleb(b, q);
      }
      else throw new Error(`unsupported import kind ${kind}`);
      if (q > end) throw new Error("truncated import section");
    }
    if (q !== end) throw new Error("import section length mismatch");
  } else if (sid === 10) {
    codeOff = p; codeSize = sz;
  } else if (sid === 0) {
    let nl; let q = p;
    [nl, q] = uleb(b, q);
    const sname = b.subarray(q, q + nl).toString("utf8");
    q += nl;
    if (sname === "name") {
      while (q < end) {
        const sub = b[q++];
        let ssz; [ssz, q] = uleb(b, q);
        const send = q + ssz;
        if (send > end) throw new Error("truncated name subsection");
        if (sub === 1) {
          let cnt; [cnt, q] = uleb(b, q);
          for (let i = 0; i < cnt; i++) {
            let idx, len2;
            [idx, q] = uleb(b, q);
            [len2, q] = uleb(b, q);
            if (q + len2 > send) throw new Error("truncated function name");
            const name = b.subarray(q, q + len2).toString("utf8");
            if (names.has(idx) && names.get(idx) !== name) throw new Error("ambiguous function name");
            names.set(idx, name);
            q += len2;
          }
          if (q !== send) throw new Error("function-name subsection length mismatch");
        }
        q = send;
      }
    }
  }
  p = end;
}
if (codeOff < 0) { console.error("no code section"); process.exit(1); }

let q = codeOff;
let cnt; [cnt, q] = uleb(b, q);
const funcs = [];
for (let i = 0; i < cnt; i++) {
  let bsz; [bsz, q] = uleb(b, q);
  if (q + bsz > codeOff + codeSize) throw new Error("truncated function body");
  funcs.push({ idx: numImportedFuncs + i, size: bsz, name: names.get(numImportedFuncs + i) || "?" });
  q += bsz;
}
if (q !== codeOff + codeSize) throw new Error("code section length mismatch");
funcs.sort((a, z) => z.size - a.size);

const total = funcs.reduce((s, f) => s + f.size, 0);
const named = funcs.filter((f) => f.name !== "?").length;
if (asJson) {
  console.log(JSON.stringify({ codeSectionBytes: codeSize, codeBytes: total,
    importedFunctions: numImportedFuncs, namedFunctions: named, functions: funcs }));
} else if (rollup) {
  const groups = new Map();
  for (const f of funcs) {
    let key = f.name;
    const expPos = key.indexOf("_exp_");
    if (expPos > 0) key = key.slice(0, expPos) + "_exp_*";
    else {
      const lam = key.indexOf("__lambda_");
      if (lam > 0) key = key.slice(0, lam) + "__lambda_*";
    }
    const g = groups.get(key) || { size: 0, n: 0 };
    g.size += f.size; g.n++;
    groups.set(key, g);
  }
  const rows = [...groups.entries()].sort((a, z) => z[1].size - a[1].size).slice(0, top);
  for (const [k, g] of rows) {
    console.log(`${String(g.size).padStart(9)} ${String(g.n).padStart(5)}x ${(100 * g.size / total).toFixed(1).padStart(5)}% ${k}`);
  }
} else {
  for (const f of funcs.slice(0, top)) {
    console.log(`${String(f.size).padStart(9)} #${String(f.idx).padStart(5)} ${(100 * f.size / total).toFixed(2).padStart(6)}% ${f.name}`);
  }
}
if (!asJson) {
  const topShare = funcs.slice(0, top).reduce((s, f) => s + f.size, 0);
  console.log(`-- code section: ${total} B across ${funcs.length} functions (${named} named); top ${top} = ${(100 * topShare / total).toFixed(1)}%`);
}
