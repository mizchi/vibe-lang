'use strict';
// #2509: the RC free-list census must count exactly what is on the free
// lists, and must REPORT -- not count -- a node that cannot be a free block.
// Each red case below mutates a known-good heap into one corruption shape and
// asserts both that the census flags it and that the flagged bytes are not
// counted as free.
const assert = require('node:assert/strict');
const test = require('node:test');
const {
  FREELIST_EXPORT,
  findRcBinsBase,
  prepareRcCensus,
  rcCensus,
  withGlobalExport,
} = require('./wasm_rc_census.js');

const BINS = 1024;
const LO = 2048;
const HI = 4096;

// A heap with two blocks in bin 0 (size 16), one in bin 2 (size 32), and two
// legacy blocks (340 and 84 bytes). Returns the memory and the legacy head.
function heap() {
  const mem = new Uint8Array(8192);
  const dv = new DataView(mem.buffer);
  const block = (at, size, next) => {
    dv.setUint32(at, size, true);
    dv.setUint32(at + 4, next, true);
    return at + 8;
  };
  const b0b = block(LO + 16, 16, 0);
  const b0a = block(LO, 16, b0b);
  dv.setUint32(BINS + 0, b0a, true);
  const b2 = block(LO + 64, 32, 0);
  dv.setUint32(BINS + 8, b2, true);
  const l2 = block(LO + 512, 84, 0);
  const l1 = block(LO + 128, 340, l2);
  return { mem, dv, head: l1, nodes: { b0a, b0b, b2, l1, l2 } };
}

const run = (h, over = {}) =>
  rcCensus({ mem: h.mem, binsBase: BINS, freelistHead: h.head, heapStart: LO, frontier: HI, ...over });

test('a clean heap is counted exactly', () => {
  const c = run(heap());
  assert.equal(c.bad, 0, c.badFirst);
  assert.equal(c.binBlocks, 3);
  assert.equal(c.binBytes, 16 + 16 + 32);
  assert.equal(c.legacyBlocks, 2);
  assert.equal(c.legacyBytes, 340 + 84);
  assert.equal(c.frontier, HI - LO);
  assert.equal(c.free, 64 + 424);
  assert.equal(c.unfreed, HI - LO - 488);
  assert.deepEqual(c.binHist.slice(0, 3), [2, 0, 1]);
});

test('empty lists report nothing free', () => {
  const mem = new Uint8Array(8192);
  const c = rcCensus({ mem, binsBase: BINS, freelistHead: 0, heapStart: LO, frontier: HI });
  assert.equal(c.bad, 0);
  assert.equal(c.free, 0);
  assert.equal(c.unfreed, HI - LO);
});

test('a stale link pointing past the frontier is flagged, not counted', () => {
  const h = heap();
  h.dv.setUint32(h.nodes.l1 - 4, HI + 64, true);
  const c = run(h);
  assert.equal(c.bad, 1);
  assert.match(c.badFirst, /^legacy:out-of-heap@/);
  assert.equal(c.legacyBlocks, 1);
  assert.equal(c.legacyBytes, 340);
});

test('a double free (a block linked twice) is flagged as an overlap', () => {
  const h = heap();
  // bin 0's tail links back to its head: the head would be handed out twice.
  h.dv.setUint32(h.nodes.b0b - 4, h.nodes.b0a, true);
  const c = run(h);
  assert.equal(c.bad, 1);
  assert.match(c.badFirst, /^bin0:overlap@/);
  assert.equal(c.binHist[0], 2);
});

test('a block that is free AND inside another free block is flagged', () => {
  const h = heap();
  // A legacy block whose span covers bin 2's block.
  h.dv.setUint32(h.nodes.l2 - 4, LO + 56 + 8, true);
  h.dv.setUint32(LO + 56, 64, true);
  h.dv.setUint32(LO + 60, 0, true);
  const c = run(h);
  assert.equal(c.bad, 1);
  assert.match(c.badFirst, /^legacy:overlap@/);
});

test('a block whose size word no longer matches its bin is flagged', () => {
  const h = heap();
  // A freed-then-reused block: its size word was overwritten after the push.
  h.dv.setUint32(h.nodes.b2 - 8, 40, true);
  const c = run(h);
  assert.equal(c.bad, 1);
  assert.match(c.badFirst, /^bin2:wrong-bin@/);
  assert.equal(c.binHist[2], 0);
});

test('an unaligned link and an oversized block are flagged', () => {
  let h = heap();
  h.dv.setUint32(h.nodes.l1 - 4, h.nodes.l2 + 2, true);
  assert.match(run(h).badFirst, /^legacy:unaligned@/);
  h = heap();
  h.dv.setUint32(h.nodes.l2 - 8, HI, true);
  assert.match(run(h).badFirst, /^legacy:bad-size@/);
});

// --- module side ---------------------------------------------------------

const leb = (n) => {
  const out = [];
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n) b |= 0x80;
    out.push(b);
  } while (n);
  return out;
};
const sleb = (n) => {
  const out = [];
  for (;;) {
    const b = n & 0x7f;
    n >>= 7;
    if ((n === 0 && !(b & 0x40)) || (n === -1 && b & 0x40)) {
      out.push(b);
      return out;
    }
    out.push(b | 0x80);
  }
};
const section = (id, body) => [id, ...leb(body.length), ...body];
const PREFIX = [
  0x20, 0x00, 0xa7, 0x22, 0x03, 0x41, 0x10, 0x6b, 0x41, 0x03, 0x78, 0x22, 0x02,
  0x41, 0x20, 0x49, 0x04, 0x40, 0x20, 0x02, 0x41, 0x02, 0x74, 0x41,
];

// A module with three mutable i32 globals (2 = 777), memory, one exported
// function `(i64) -> ()` whose body runs the allocator's opening sequence once
// per entry of `basesInCode`, and an export section.
function module(basesInCode) {
  const type = section(1, [1, 0x60, 1, 0x7e, 0]);
  const func = section(3, [1, 0]);
  const mem = section(5, [1, 0, 1]);
  const g = (v) => [0x7f, 1, 0x41, ...sleb(v), 0x0b];
  const globals = section(6, [3, ...g(0), ...g(0), ...g(777)]);
  const exports = section(7, [2, 3, ...Buffer.from('run'), 0, 0, 6, ...Buffer.from('memory'), 2, 0]);
  // ... i32.const <base>; i32.add; drop; end (of the prefix's `if`)
  const seq = basesInCode.flatMap((b) => [...PREFIX, ...sleb(b), 0x6a, 0x1a, 0x0b]);
  const body = [1, 3, 0x7f, ...seq, 0x0b];
  const code = section(10, [1, ...leb(body.length), ...body]);
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...type, ...func, ...mem, ...globals, ...exports, ...code]);
}

test('the bins base is read from the allocator code, and must be unique', () => {
  assert.equal(findRcBinsBase(module([70000])), 70000);
  assert.equal(findRcBinsBase(module([70000, 70000])), 70000);
  assert.equal(findRcBinsBase(module([70000, 70008])), null);
  assert.equal(findRcBinsBase(module([])), null);
});

test('the added export reads global 2 and changes nothing else', async () => {
  const bytes = module([70000]);
  const prep = prepareRcCensus(bytes);
  assert.equal(prep.binsBase, 70000);
  assert.equal(prep.bytes.length, bytes.length + 2 + FREELIST_EXPORT.length + 1);
  const { instance } = await WebAssembly.instantiate(prep.bytes, {});
  assert.equal(instance.exports[FREELIST_EXPORT].value, 777);
  assert.equal(typeof instance.exports.run, 'function');
  // Every section other than the export section is byte-identical.
  const strip = (b) => {
    const out = [];
    let pos = 8;
    while (pos < b.length) {
      const id = b[pos];
      let size = 0, shift = 0, q = pos + 1, x;
      do { x = b[q++]; size |= (x & 0x7f) << shift; shift += 7; } while (x & 0x80);
      if (id !== 7) out.push(Buffer.from(b.subarray(pos, q + size)).toString('hex'));
      pos = q + size;
    }
    return out;
  };
  assert.deepEqual(strip(prep.bytes), strip(bytes));
});

test('a module without an RC allocator is left alone', () => {
  const bytes = module([]);
  const prep = prepareRcCensus(bytes);
  assert.equal(prep.binsBase, null);
  assert.equal(prep.reason, 'no-rc-allocator');
  assert.equal(prep.bytes, bytes);
  assert.ok(withGlobalExport(bytes, 2, 'x').length > bytes.length);
});
