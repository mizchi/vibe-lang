"use strict";
// RC free-list census (#2509): split the linear RC allocator's frontier into
// bytes sitting on its free lists and bytes that were never returned to them.
//
// Opt-in, host-side, read-only. `VIBE_WASM_RC_CENSUS=1` makes the node runner
// (scripts/wasm_vibe_host_runner.js) do two things to an RC-lane module, and
// nothing to any other module:
//
//   1. Before compiling it, append ONE export -- `__rc_freelist`, the legacy
//      free-list head (global 2) -- to the export section. No code, global,
//      data or memory byte changes, so the guest computes exactly what it
//      computes without the census. The rewritten bytes exist only in this
//      process; the artifact on disk is untouched.
//   2. At every `[profile-memory]` mark, and at the end of the run, walk the
//      32 exact-size bins and the legacy list in guest memory and print one
//      `[rc-census]` line.
//
// What it reads (docs/internal/design/uniform-value-repr.md, ADR-0092). A free
// block is a value pointer p (block + 8): its size word at p-8 and its link
// at p-4. Bins hold sizes 16..264, 8-aligned, at `bins_base + 4*i`; anything
// else goes on the legacy LIFO list headed by global 2. `bins_base` is a
// compile-time constant of the emitted module, so it is read out of the
// allocator's own code: the first instructions of `__rt_rc_alloc` are
//
//   local.get 0; i32.wrap_i64; local.tee 3; i32.const 16; i32.sub;
//   i32.const 3; i32.rotr; local.tee 2; i32.const 32; i32.lt_u; if;
//   local.get 2; i32.const 2; i32.shl; i32.const <bins_base>; i32.add
//
// and every occurrence of that prefix must agree, or the census declines.
//
// What it does NOT measure. `unfreed = frontier - free` counts every byte
// below the frontier that is not on a free list: reachable RC blocks, RC
// blocks that leaked (a missing release), cyclic garbage, and the byte
// allocations that never carry an RC header (string/bytes payloads). The
// heap is not walkable (headerless byte allocations sit between headered
// blocks), so no host-side reading separates those exactly. `unfreed` is
// therefore an UPPER BOUND on live RC bytes; `free` is exact. `detail` adds a
// heuristic split of `unfreed` (walkUnfreed, below), labelled `est_`.
//
// Integrity. Every node is checked as it is read: inside
// [heap_start + 8, frontier], 8-aligned, with a size of at least its header
// whose block ends at or below the frontier, in the bin its size belongs to
// (bins), and not overlapping any other free block (a granule bitmap over the
// walked range). A violation is counted in `bad=` and named in `bad_first=`;
// the walk of that list stops there, so a corrupt link cannot make the census
// read garbage as free bytes. scripts/wasm_rc_census.test.cjs mutates a
// synthetic heap into each of those shapes and asserts that it is reported.
//
// Measurements made with it: docs/internal/reports/rc-live-bytes-2026-11-09.md.

const RC_ALLOC_PREFIX = [
  0x20, 0x00, 0xa7, 0x22, 0x03, 0x41, 0x10, 0x6b, 0x41, 0x03, 0x78, 0x22, 0x02,
  0x41, 0x20, 0x49, 0x04, 0x40, 0x20, 0x02, 0x41, 0x02, 0x74, 0x41,
];
const BIN_COUNT = 32;
const FREELIST_GLOBAL = 2;
const FREELIST_EXPORT = "__rc_freelist";

function readU32Leb(bytes, pos) {
  let result = 0;
  let shift = 0;
  for (;;) {
    const b = bytes[pos++];
    result += (b & 0x7f) * 2 ** shift;
    shift += 7;
    if ((b & 0x80) === 0) return { value: result, pos };
  }
}

function readI32Leb(bytes, pos) {
  let result = 0;
  let shift = 0;
  let b;
  do {
    b = bytes[pos++];
    result |= (b & 0x7f) << shift;
    shift += 7;
  } while (b & 0x80);
  if (shift < 32 && (b & 0x40)) result |= -1 << shift;
  return { value: result | 0, pos };
}

function encodeU32Leb(value) {
  const out = [];
  do {
    let b = value & 0x7f;
    value = Math.floor(value / 128);
    if (value !== 0) b |= 0x80;
    out.push(b);
  } while (value !== 0);
  return out;
}

function sections(bytes) {
  const out = [];
  let pos = 8;
  while (pos < bytes.length) {
    const id = bytes[pos];
    const size = readU32Leb(bytes, pos + 1);
    out.push({ id, start: pos, bodyStart: size.pos, end: size.pos + size.value });
    pos = size.pos + size.value;
  }
  return out;
}

// The bins base the module's own allocator uses, or null when the module has
// no RC allocator (bump lane, gc lane) or its occurrences disagree.
function findRcBinsBase(bytes) {
  const code = sections(bytes).find((s) => s.id === 10);
  if (!code) return null;
  const values = new Set();
  const first = RC_ALLOC_PREFIX[0];
  outer: for (let i = code.bodyStart; i + RC_ALLOC_PREFIX.length < code.end; i++) {
    if (bytes[i] !== first) continue;
    for (let k = 1; k < RC_ALLOC_PREFIX.length; k++) {
      if (bytes[i + k] !== RC_ALLOC_PREFIX[k]) continue outer;
    }
    const leb = readI32Leb(bytes, i + RC_ALLOC_PREFIX.length);
    if (bytes[leb.pos] !== 0x6a) continue;
    values.add(leb.value >>> 0);
  }
  return values.size === 1 ? [...values][0] : null;
}

function countImportedGlobals(bytes) {
  const imp = sections(bytes).find((s) => s.id === 2);
  if (!imp) return 0;
  let pos = imp.bodyStart;
  const n = readU32Leb(bytes, pos);
  pos = n.pos;
  let globals = 0;
  for (let i = 0; i < n.value; i++) {
    for (let k = 0; k < 2; k++) {
      const len = readU32Leb(bytes, pos);
      pos = len.pos + len.value;
    }
    const kind = bytes[pos++];
    if (kind === 0) {
      pos = readU32Leb(bytes, pos).pos;
    } else if (kind === 1) {
      pos += 1;
      const flags = bytes[pos++];
      pos = readU32Leb(bytes, pos).pos;
      if (flags & 1) pos = readU32Leb(bytes, pos).pos;
    } else if (kind === 2) {
      const flags = bytes[pos++];
      pos = readU32Leb(bytes, pos).pos;
      if (flags & 1) pos = readU32Leb(bytes, pos).pos;
    } else if (kind === 3) {
      pos += 2;
      globals += 1;
    } else if (kind === 4) {
      pos += 1;
      pos = readU32Leb(bytes, pos).pos;
    } else {
      return null;
    }
  }
  return globals;
}

function exportNames(bytes) {
  const exp = sections(bytes).find((s) => s.id === 7);
  if (!exp) return [];
  let pos = exp.bodyStart;
  const n = readU32Leb(bytes, pos);
  pos = n.pos;
  const names = [];
  for (let i = 0; i < n.value; i++) {
    const len = readU32Leb(bytes, pos);
    names.push(Buffer.from(bytes.subarray(len.pos, len.pos + len.value)).toString("utf8"));
    pos = len.pos + len.value + 1;
    pos = readU32Leb(bytes, pos).pos;
  }
  return names;
}

// A copy of `bytes` whose export section also exports global `globalIdx` as
// `name`. Nothing else changes.
function withGlobalExport(bytes, globalIdx, name) {
  const secs = sections(bytes);
  const exp = secs.find((s) => s.id === 7);
  const entry = [...encodeU32Leb(Buffer.byteLength(name)), ...Buffer.from(name), 0x03, ...encodeU32Leb(globalIdx)];
  let body;
  if (exp) {
    const n = readU32Leb(bytes, exp.bodyStart);
    body = Buffer.concat([
      Buffer.from(encodeU32Leb(n.value + 1)),
      Buffer.from(bytes.subarray(n.pos, exp.end)),
      Buffer.from(entry),
    ]);
  } else {
    body = Buffer.concat([Buffer.from([1]), Buffer.from(entry)]);
  }
  const section = Buffer.concat([Buffer.from([7]), Buffer.from(encodeU32Leb(body.length)), body]);
  if (exp) {
    return Buffer.concat([Buffer.from(bytes.subarray(0, exp.start)), section, Buffer.from(bytes.subarray(exp.end))]);
  }
  // Export section order: after id 6 (global), before id 8 (start).
  const after = secs.find((s) => s.id > 7 && s.id !== 0);
  const cut = after ? after.start : bytes.length;
  return Buffer.concat([Buffer.from(bytes.subarray(0, cut)), section, Buffer.from(bytes.subarray(cut))]);
}

// Prepare a module for the census. Returns { bytes, binsBase } or
// { bytes: original, binsBase: null, reason } when it does not apply.
function prepareRcCensus(bytes) {
  const binsBase = findRcBinsBase(bytes);
  if (binsBase === null) return { bytes, binsBase: null, reason: "no-rc-allocator" };
  const imported = countImportedGlobals(bytes);
  if (imported === null) return { bytes, binsBase: null, reason: "unreadable-imports" };
  if (imported > FREELIST_GLOBAL) return { bytes, binsBase: null, reason: "freelist-global-imported" };
  if (exportNames(bytes).includes(FREELIST_EXPORT)) return { bytes, binsBase, reason: null };
  return { bytes: withGlobalExport(bytes, FREELIST_GLOBAL, FREELIST_EXPORT), binsBase, reason: null };
}

function u32(v) {
  return typeof v === "bigint" ? Number(BigInt.asUintN(32, v)) : v >>> 0;
}

// Walk the free lists. With `walk` (true, or a per-block sampler
// `(x, size, cls, count)`), also estimate the unfreed split (walkUnfreed). `mem` is a Uint8Array over guest memory; `heapStart`
// the frontier before the guest ran; `frontier` the current one. Pure: it
// only reads `mem`.
function rcCensus({ mem, binsBase, freelistHead, heapStart, frontier, walk = false }) {
  const dv = new DataView(mem.buffer, mem.byteOffset, mem.byteLength);
  const lo = heapStart;
  const hi = frontier;
  const granules = Math.ceil(Math.max(0, hi - lo) / 8);
  const seen = new Uint8Array(Math.ceil(granules / 8));
  const out = {
    frontier: Math.max(0, hi - lo),
    binBytes: 0,
    binBlocks: 0,
    legacyBytes: 0,
    legacyBlocks: 0,
    bad: 0,
    badFirst: "",
    binHist: new Array(BIN_COUNT).fill(0),
    legacyHist: new Map(),
  };
  const fail = (what) => {
    out.bad += 1;
    if (!out.badFirst) out.badFirst = what;
    return false;
  };
  // Independent of the overlap check: no list can hold more nodes than the
  // walked range has granules, so a longer walk is a cycle.
  let budget = granules + 1;
  const claim = (p, size, where) => {
    if (--budget < 0) return fail(`${where}:cycle@${p}`);
    if (p < lo + 8 || p > hi) return fail(`${where}:out-of-heap@${p}`);
    if (p & 7) return fail(`${where}:unaligned@${p}`);
    // Bin blocks are 16..264, 8-aligned; a legacy block may be any size of at
    // least its header (an array or bytes buffer freed by its grow path keeps
    // the byte count it was allocated with).
    if (size < 8 || p - 8 + size > hi) return fail(`${where}:bad-size@${p}:${size}`);
    const g0 = (p - 8 - lo) / 8;
    const g1 = g0 + Math.ceil(size / 8);
    for (let g = g0; g < g1; g++) {
      const m = 1 << (g & 7);
      if (seen[g >> 3] & m) return fail(`${where}:overlap@${p}`);
      seen[g >> 3] |= m;
    }
    return true;
  };
  const rd = (a) => (a >= 0 && a + 4 <= mem.length ? dv.getUint32(a, true) : null);
  for (let i = 0; i < BIN_COUNT; i++) {
    const want = 16 + 8 * i;
    let p = rd(binsBase + 4 * i);
    if (p === null) {
      fail(`bins:unreadable@${binsBase}`);
      break;
    }
    while (p !== 0) {
      const size = rd(p - 8);
      if (size === null) { fail(`bin${i}:unreadable@${p}`); break; }
      if (size !== want) { fail(`bin${i}:wrong-bin@${p}:${size}`); break; }
      if (!claim(p, size, `bin${i}`)) break;
      out.binBytes += size;
      out.binBlocks += 1;
      out.binHist[i] += 1;
      p = rd(p - 4);
      if (p === null) { fail(`bin${i}:unreadable-link`); break; }
    }
  }
  let p = freelistHead;
  while (p !== 0) {
    const size = rd(p - 8);
    if (size === null) { fail(`legacy:unreadable@${p}`); break; }
    if (!claim(p, size, "legacy")) break;
    out.legacyBytes += size;
    out.legacyBlocks += 1;
    out.legacyHist.set(size, (out.legacyHist.get(size) || 0) + 1);
    p = rd(p - 4);
    if (p === null) { fail("legacy:unreadable-link"); break; }
  }
  out.free = out.binBytes + out.legacyBytes;
  out.unfreed = out.frontier - out.free;
  if (walk && out.bad === 0) out.walk = walkUnfreed(dv, lo, hi, seen, typeof walk === "function" ? walk : null);
  return out;
}

const LIVE_CLASSES = new Set([0, 1, 5, 6, 7, 8, 9]);

// Heuristic split of the UNFREED bytes (detail mode only). The heap is not
// walkable -- string and bytes payloads carry no header -- so this scans the
// 8-byte granules below the frontier: a granule on a free list is skipped; a
// granule that reads as a plausible RC header (a known drop class, a size that
// ends below the frontier, and for the field-vector and closure classes a size
// that equals 16 + 8 * its field count) is taken as one live block and its
// whole span skipped, provided no granule inside it is free; anything else is counted as `raw` (headerless payload
// or host-written buffers) and the scan moves 8 bytes on. Text does not read
// as a header (its "size" is four ASCII bytes, far past any frontier under
// 1 GiB, and its "class" byte is printable), but a raw run can contain one
// by chance, so these numbers are an estimate and are labelled as such.
function walkUnfreed(dv, lo, hi, seen, sample) {
  const res = { rcBytes: 0, rcBlocks: 0, rawBytes: 0, immortalBytes: 0, byClass: new Map(), bySig: new Map() };
  let x = lo + ((8 - (lo & 7)) & 7);
  res.rawBytes += x - lo;
  while (x + 8 <= hi) {
    const g = (x - lo) >> 3;
    if (seen[g >> 3] & (1 << (g & 7))) { x += 8; continue; }
    const size = dv.getUint32(x, true);
    const word = dv.getUint32(x + 4, true);
    const cls = word >>> 24;
    const count = word & 0xffffff;
    let ok = size >= 16 && x + size <= hi && LIVE_CLASSES.has(cls) && count > 0;
    if (ok && (cls === 1 || cls === 7) && x + 16 <= hi) ok = size === 16 + 8 * dv.getUint32(x + 12, true);
    const span = Math.ceil(size / 8) * 8;
    // A live block contains no free granule; a span that does is a stale or
    // accidental header, not a block.
    if (ok) {
      for (let k = g + 1, e = g + span / 8; k < e; k++) {
        if (seen[k >> 3] & (1 << (k & 7))) { ok = false; break; }
      }
    }
    if (!ok) { res.rawBytes += 8; x += 8; continue; }
    res.rcBytes += span;
    res.rcBlocks += 1;
    if (count === 0xffffff) res.immortalBytes += span;
    res.byClass.set(cls, (res.byClass.get(cls) || 0) + span);
    const sig = cls === 1 ? `c1/${size}/t${dv.getUint32(x + 8, true)}` : `c${cls}/${size}`;
    const e = res.bySig.get(sig);
    if (e) { e.n += 1; e.bytes += span; } else res.bySig.set(sig, { n: 1, bytes: span });
    if (sample) sample(x, size, cls, count);
    x += span;
  }
  if (x < hi) res.rawBytes += hi - x;
  return res;
}

function formatCensus(label, c, extra) {
  const pct = c.frontier > 0 ? ((100 * c.free) / c.frontier).toFixed(2) : "0.00";
  let line =
    `[rc-census] ${label} frontier=${c.frontier} free=${c.free} unfreed=${c.unfreed} free_pct=${pct}` +
    ` bin_bytes=${c.binBytes} bin_blocks=${c.binBlocks} legacy_bytes=${c.legacyBytes} legacy_blocks=${c.legacyBlocks}` +
    ` bad=${c.bad}${c.badFirst ? ` bad_first=${c.badFirst}` : ""}${extra || ""}`;
  if (process.env.VIBE_WASM_RC_CENSUS === "detail") {
    const bins = c.binHist.map((n, i) => `${16 + 8 * i}:${n}`).filter((s) => !s.endsWith(":0")).join(",");
    const top = [...c.legacyHist.entries()]
      .sort((a, b) => b[0] * b[1] - a[0] * a[1])
      .slice(0, 12)
      .map(([sz, n]) => `${sz}x${n}`)
      .join(",");
    line += ` bins=${bins || "-"} legacy_top=${top || "-"}`;
    if (c.walk) {
      const w = c.walk;
      const cls = [...w.byClass.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => `c${k}:${v}`).join(",");
      const sigs = [...w.bySig.entries()]
        .sort((a, b) => b[1].bytes - a[1].bytes)
        .slice(0, 16)
        .map(([k, v]) => `${k}x${v.n}=${v.bytes}`)
        .join(",");
      line += ` est_rc_live_bytes=${w.rcBytes} est_rc_live_blocks=${w.rcBlocks} est_raw_bytes=${w.rawBytes}` +
        ` est_immortal_bytes=${w.immortalBytes} est_by_class=${cls || "-"} est_top=${sigs || "-"}`;
    }
  }
  return line;
}

// Host-side state: set once after instantiation, read at each mark.
function createRcCensusReader(instance, binsBase) {
  const g = instance.exports[FREELIST_EXPORT];
  const hp = instance.exports.__heap_ptr;
  if (!(g instanceof WebAssembly.Global) || !(hp instanceof WebAssembly.Global)) return null;
  const heapStart = u32(hp.value);
  return (label) => {
    const mem = new Uint8Array(instance.exports.memory.buffer);
    const t0 = process.hrtime.bigint();
    const walk = process.env.VIBE_WASM_RC_CENSUS === "detail";
    const c = rcCensus({ mem, binsBase, freelistHead: u32(g.value), heapStart, frontier: u32(hp.value), walk });
    const us = Number((process.hrtime.bigint() - t0) / 1000n);
    console.error(formatCensus(label, c, ` census_us=${us}`));
    // VIBE_WASM_RC_CENSUS_DUMP=<file>: at the end of the run, also write the
    // guest memory below the frontier plus a JSON sidecar (heap_start,
    // frontier, bins_base, legacy head) for offline analysis.
    const dump = process.env.VIBE_WASM_RC_CENSUS_DUMP;
    if (dump && label === "end") {
      const fs = require("fs");
      fs.writeFileSync(dump, mem.subarray(0, u32(hp.value)));
      fs.writeFileSync(`${dump}.json`, JSON.stringify({ heapStart, frontier: u32(hp.value), binsBase, freelistHead: u32(g.value) }));
    }
    return c;
  };
}

module.exports = {
  FREELIST_EXPORT,
  createRcCensusReader,
  findRcBinsBase,
  formatCensus,
  prepareRcCensus,
  rcCensus,
  withGlobalExport,
};
