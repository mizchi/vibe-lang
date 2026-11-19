// Read the two slot arrays after guest code has returned. Observing through
// the Wasm memory leaves each occupied Option box's reference count intact.
const assert = require("node:assert/strict");
const fs = require("node:fs");

const wasm = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
function unexpectedOutput() {
  throw new Error("unexpected output from the MutMap fixture");
}
const imports = {
  wasi_snapshot_preview1: { fd_write: unexpectedOutput },
  vibe: { stdout_write_stream: unexpectedOutput, stdout_write_char: unexpectedOutput },
};

// Each offset starts with an empty map. The second moves all eleven
// pre-growth entries from the lower into the upper half of the new table.
const { main, memory } = new WebAssembly.Instance(wasm, imports).exports;
const result = 2 * Number(main(0n));
const view = new DataView(memory.buffer);
const u32 = address => view.getUint32(address, true);
function pointer(address) {
  const tagged = view.getBigUint64(address, true);
  assert.equal(tagged & 1n, 1n);
  return Number(tagged - 1n);
}
function inspect(array) {
  assert.equal(u32(array + 4), 32, "capacity after one rehash");
  const data = u32(array + 8);
  return Array.from({ length: 32 }, (_, i) => {
    const box = pointer(data + 8 * i);
    if (u32(box + 4) === 0) return null;
    assert.equal(u32(box + 4), 1, "Some has one field");
    const value = Number(view.getBigInt64(box + 8, true) >> 1n);
    assert.equal(u32(box - 4) & 0xffffff, 1, `count for Some(${value})`);
    return value;
  });
}

// The RC entry adapter shifts away the return tag. The pair owns the
// arrays, and only the arrays own their individual Some boxes.
for (const [index, offset] of [0, 16].entries()) {
  const pair = pointer(result + 8 + 8 * index);
  const keys = inspect(pointer(pair + 8));
  const values = inspect(pointer(pair + 16));
  for (let i = 0; i < keys.length; i++) {
    assert.equal(values[i], keys[i] === null ? null : keys[i] + 100);
  }
  assert.deepEqual(keys.filter(k => k !== null).sort((a, b) => a - b),
    Array.from({ length: 20 }, (_, i) => i + offset));
}
