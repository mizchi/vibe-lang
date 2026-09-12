#!/usr/bin/env node
// wasm_index_stability.mjs -- what would a per-module BODY cache have to
// relocate between two builds? (#2669 / #2510 criterion 5)
//
//   node scripts/wasm_index_stability.mjs <a.wasm> <b.wasm>
//
// Both inputs must be built with VIBE_WASM_NAMES=1: functions are matched
// across the two modules BY NAME, because matching them by index would assume
// the very stability being measured. Release builds are stripped (ADR-0077),
// so a stripped input is REFUSED rather than reported as clean.
//
// docs/incremental-build.md records the constraint this exists to quantify: a
// cached function body carries call immediates, and those depend on GLOBAL
// function index assignment, so a body cannot simply be replayed into a build
// where indices moved. "Moved" is the part nobody had measured. This reports
// it, in the three quantities the answer turns on:
//
//   1. INDEX STABILITY -- how many functions keep their index, and when they
//      move, whether the deltas are one uniform shift (a positional
//      assignment, relocatable by arithmetic) or scattered (which would mean
//      only a symbolic form can survive).
//   2. BODY BYTES -- how many bodies are byte-identical (replayable verbatim),
//      how many differ at the SAME length (patchable in place), and how many
//      change length (a rewrite that moves everything after it).
//   3. RELOCATION SITES -- for each same-length difference, what KIND of
//      immediate moved. This is the part that resists guessing: a `call`
//      immediate announces itself by opcode, but a first-class function value
//      is emitted as `i64.const (idx*4+2)` and looks like any other constant.
//      A relocation pass keyed on the call opcode alone would leave those
//      silently wrong, which is the worst way for this to break.
//
// A measurement, not a gate: it reports and exits 0 when it could answer, so
// there is no pass/fail property for a companion `_test.sh` to red-test
// (scripts/prelude_split_memory.sh carries the same note). It exits non-zero
// only when it could NOT answer -- an unreadable module, or no name section --
// because a gate that cannot see must not be indistinguishable from one that
// looked and found nothing (#2248).
//
// Non-vacuity is reported rather than assumed: the site classification prints
// the number of differing byte positions it EXPLAINED next to the number it
// could not. "0 unexplained" says nothing on its own; "31405 explained, 0
// unexplained" does.

import { readFileSync } from "node:fs";

function uleb(b, p) {
  let r = 0n, s = 0n, x;
  do { x = b[p++]; r |= BigInt(x & 0x7f) << s; s += 7n; } while (x & 0x80);
  return [Number(r), p];
}
function sleb(b, p) {
  let r = 0n, s = 0n, x;
  do { x = b[p++]; r |= BigInt(x & 0x7f) << s; s += 7n; } while (x & 0x80);
  if (x & 0x40) r -= 1n << s;
  return [Number(r), p];
}

// Read the function name table and every defined function body. Imports are
// walked rather than skipped: they occupy the low end of the function index
// space, so a call immediate is only interpretable once their count is known.
function readModule(file) {
  let b;
  try { b = readFileSync(file); } catch (e) { fail(`cannot read ${file}: ${e.message}`); }
  if (b.length < 8 || b.readUInt32LE(0) !== 0x6d736100) fail(`${file} is not a wasm module`);
  let p = 8, imported = 0;
  const names = new Map(), bodies = new Map();
  while (p < b.length) {
    const sid = b[p++];
    let size; [size, p] = uleb(b, p);
    const end = p + size;
    if (sid === 2) {
      let n; [n, p] = uleb(b, p);
      for (let i = 0; i < n; i++) {
        let len; [len, p] = uleb(b, p); p += len;      // module
        [len, p] = uleb(b, p); p += len;               // field
        const kind = b[p++];
        let ignored;
        if (kind === 0) { [ignored, p] = uleb(b, p); imported++; }
        else if (kind === 1) { p++; const fl = b[p++]; [ignored, p] = uleb(b, p); if (fl) [ignored, p] = uleb(b, p); }
        else if (kind === 2) { const fl = b[p++]; [ignored, p] = uleb(b, p); if (fl) [ignored, p] = uleb(b, p); }
        else if (kind === 3) { p += 2; }
        else fail(`${file}: unknown import kind ${kind}`);
      }
      p = end;
    } else if (sid === 10) {
      let n; [n, p] = uleb(b, p);
      for (let i = 0; i < n; i++) {
        let size2; [size2, p] = uleb(b, p);
        bodies.set(imported + i, b.subarray(p, p + size2));
        p += size2;
      }
      p = end;
    } else if (sid === 0) {
      let len, q = p; [len, q] = uleb(b, q);
      const secName = b.toString("utf8", q, q + len); q += len;
      if (secName === "name") {
        while (q < end) {
          const sub = b[q++];
          let subSize; [subSize, q] = uleb(b, q);
          const subEnd = q + subSize;
          if (sub === 1) {
            let count; [count, q] = uleb(b, q);
            for (let i = 0; i < count; i++) {
              let idx, nlen;
              [idx, q] = uleb(b, q);
              [nlen, q] = uleb(b, q);
              names.set(idx, b.toString("utf8", q, q + nlen));
              q += nlen;
            }
          }
          q = subEnd;
        }
      }
      p = end;
    } else p = end;
  }
  if (names.size === 0) {
    fail(`${file} has no function name section; build it with VIBE_WASM_NAMES=1 ` +
         `(release builds are stripped, ADR-0077) -- without names the two modules ` +
         `can only be matched by index, which is what this measures`);
  }
  return { names, bodies, imported };
}

function fail(msg) { console.error(`wasm_index_stability: ${msg}`); process.exit(2); }

// Minimal-width uleb128 -- lib/@vibe/compiler/core/bytebuf.vibe emits exactly
// this, so an immediate's byte width tracks the magnitude of the index in it.
const lebWidth = (n) => (n < 128 ? 1 : n < 16384 ? 2 : n < 2097152 ? 3 : 4);

// A first-class function value on the linear lane is `i64.const (idx*4+2)`:
// the function index is tagged once as a function reference and once as an
// Int. Recovered here so a moved function REFERENCE is reported as what it is
// rather than as an unexplained constant.
const fnValueIndex = (v) => (v >= 2 && v % 4 === 2 ? (v - 2) / 4 : null);

const [fileA, fileB] = process.argv.slice(2);
if (!fileA || !fileB) {
  console.error("usage: node scripts/wasm_index_stability.mjs <a.wasm> <b.wasm>");
  process.exit(2);
}
const A = readModule(fileA), B = readModule(fileB);
const indexA = new Map(), indexB = new Map();
for (const [i, n] of A.names) indexA.set(n, i);
for (const [i, n] of B.names) indexB.set(n, i);

const common = [...indexA.keys()].filter(
  (n) => indexB.has(n) && A.bodies.has(indexA.get(n)) && B.bodies.has(indexB.get(n)));
if (common.length === 0) fail("the two modules share no named defined function; nothing to compare");

const onlyA = [...indexA.keys()].filter((n) => !indexB.has(n));
const onlyB = [...indexB.keys()].filter((n) => !indexA.has(n));

// 1. index stability
let kept = 0, movedWidth = 0;
const shifts = new Map();
for (const n of common) {
  const ia = indexA.get(n), ib = indexB.get(n);
  if (ia === ib) { kept++; continue; }
  shifts.set(ib - ia, (shifts.get(ib - ia) || 0) + 1);
  if (lebWidth(ia) !== lebWidth(ib)) movedWidth++;
}
const moved = common.length - kept;

// 2. body bytes
let identical = 0, sameLen = 0, diffLen = 0;
const lenChanges = [];
for (const n of common) {
  const a = A.bodies.get(indexA.get(n)), b = B.bodies.get(indexB.get(n));
  if (a.length === b.length) { if (a.equals(b)) identical++; else sameLen++; }
  else { diffLen++; if (lenChanges.length < 5) lenChanges.push(`${n} ${a.length}->${b.length}`); }
}

// 3. relocation sites, for the same-length differences only: those are the
// ones an in-place patch could serve, so what is IN them decides whether such
// a patch can be written.
const OPCODE = { 0x42: "i64.const", 0x41: "i32.const", 0x10: "call", 0x11: "call_indirect", 0x23: "global.get", 0xd2: "ref.func" };
let explained = 0, unexplained = 0, viaCall = 0, viaFnValue = 0, carries = 0, noOpcode = 0;
const deltas = new Map();
// Deltas of the sites that could NOT be attributed. Reported, never named:
// a bare `i64.const 288 -> 348` has no cross-check that says what it is, and
// this tool's rule is that an absent classification is fine while a wrong one
// is not (the fn-value arm only claims a site when the decoded index carries
// the same NAME on both sides). The histogram is interpretation-free and is
// what makes the class legible anyway -- on a module reorder it came back
// -101:578 +60:268 plus one +257698037760, and that last one is (60 << 32),
// i.e. a `(ptr<<32)|len` String whose DATA pointer moved 60 bytes with its
// length unchanged. Structure like that says "one moved segment", not noise.
const unexplainedDeltas = new Map();
const unexplainedSamples = [];
for (const n of common) {
  const a = A.bodies.get(indexA.get(n)), b = B.bodies.get(indexB.get(n));
  if (a.length !== b.length || a.equals(b)) continue;
  let i = 0;
  while (i < a.length) {
    if (a[i] === b[i]) { i++; continue; }
    // Walk back to the nearest opcode whose immediate could cover this byte.
    // `at` therefore lands BEHIND `i`, which is why every advance below goes
    // through `advance` rather than jumping to the end of the immediate
    // directly: an immediate that ends at or before `i` would otherwise move
    // `i` backwards and the same difference would be re-found forever. That
    // is not hypothetical -- it hung for 15+ minutes on the first module pair
    // whose indices moved by more than one, because there a differing byte can
    // sit several bytes into an immediate whose opcode is further back still.
    // Deltas of +1 never reached it: there the differing byte is the first
    // byte after the opcode, so at = i - 1 and the jump always went forward.
    let op = null, at = -1;
    for (let k = 1; k <= 6 && i - k >= 0; k++) {
      if (OPCODE[a[i - k]] !== undefined) { op = OPCODE[a[i - k]]; at = i - k; break; }
    }
    const advance = (end) => { i = Math.max(i + 1, end); };
    const signed = op === "i64.const" || op === "i32.const";
    const va = op ? (signed ? sleb(a, at + 1)[0] : uleb(a, at + 1)[0]) : null;
    const vb = op ? (signed ? sleb(b, at + 1)[0] : uleb(b, at + 1)[0]) : null;
    const widthA = op ? (signed ? sleb(a, at + 1)[1] : uleb(a, at + 1)[1]) - at - 1 : 0;
    const widthB = op ? (signed ? sleb(b, at + 1)[1] : uleb(b, at + 1)[1]) - at - 1 : 0;
    if (op === "call" || op === "global.get" || op === "ref.func") {
      explained++; viaCall++;
      deltas.set(vb - va, (deltas.get(vb - va) || 0) + 1);
      if (widthA !== widthB) movedWidth++;
      if (widthA > 1) carries += widthA - 1;
      advance(at + 1 + widthA);
      continue;
    }
    const fa = op === "i64.const" ? fnValueIndex(va) : null;
    const fb = op === "i64.const" ? fnValueIndex(vb) : null;
    // A function VALUE is only claimed as such when both sides decode to a
    // function index AND the two indices carry the same NAME -- otherwise an
    // ordinary integer constant that happens to be 2 mod 4 would be counted
    // as a relocation site it is not.
    if (fa !== null && fb !== null && A.names.get(fa) !== undefined && A.names.get(fa) === B.names.get(fb)) {
      explained++; viaFnValue++;
      deltas.set(fb - fa, (deltas.get(fb - fa) || 0) + 1);
      advance(at + 1 + widthA);
      continue;
    }
    unexplained++;
    if (op !== null) unexplainedDeltas.set(vb - va, (unexplainedDeltas.get(vb - va) || 0) + 1);
    else noOpcode++;
    if (unexplainedSamples.length < 6) {
      unexplainedSamples.push(`${n}@${i} ${op ?? "?"} ${va} -> ${vb}`);
    }
    // Advance past the immediate, like the explained arms: counting each BYTE
    // of one multi-byte immediate as its own site inflated the figure (1696
    // bytes for 850 sites on the reorder pair below).
    advance(op !== null ? at + 1 + widthA : i + 1);
  }
}

const pct = (x, of) => (of === 0 ? "n/a" : `${((x * 100) / of).toFixed(2)}%`);
const histo = (m) => [...m.entries()].sort((x, y) => y[1] - x[1]).map(([d, c]) => `${d >= 0 ? "+" : ""}${d}:${c}`);

console.log(`a ${fileA}`);
console.log(`b ${fileB}`);
console.log(`functions a=${A.bodies.size} b=${B.bodies.size} imports=${A.imported}/${B.imported} matched-by-name=${common.length}`);
console.log(`only-in-a ${onlyA.length}${onlyA.length && onlyA.length <= 3 ? ` ${onlyA.join(",")}` : ""}`);
console.log(`only-in-b ${onlyB.length}${onlyB.length && onlyB.length <= 3 ? ` ${onlyB.join(",")}` : ""}`);
console.log(`index kept=${kept} (${pct(kept, common.length)}) moved=${moved} (${pct(moved, common.length)})`);
console.log(`index shift-deltas ${moved === 0 ? "(none)" : histo(shifts).slice(0, 8).join(" ") + (shifts.size > 8 ? ` ... ${shifts.size} distinct` : ` (${shifts.size} distinct)`)}`);
console.log(`index width-band-crossings ${movedWidth}`);
console.log(`body identical=${identical} (${pct(identical, common.length)}) same-length-differ=${sameLen} (${pct(sameLen, common.length)}) length-changed=${diffLen} (${pct(diffLen, common.length)})`);
if (lenChanges.length) console.log(`body length-changed-examples ${lenChanges.join(" | ")}`);
console.log(`sites explained=${explained} unexplained=${unexplained} (call-immediate=${viaCall} fn-value-i64const=${viaFnValue} no-opcode-within-6-bytes=${noOpcode})`);
console.log(`sites value-deltas ${explained === 0 ? "(none)" : histo(deltas).slice(0, 8).join(" ") + ` (${deltas.size} distinct)`}`);
console.log(`sites unexplained-deltas ${unexplained === 0 ? "(none)" : histo(unexplainedDeltas).slice(0, 8).join(" ") + ` (${unexplainedDeltas.size} distinct)`}`);
if (unexplainedSamples.length) console.log(`sites unexplained-samples ${unexplainedSamples.join(" | ")}`);
