// The exported thunk reads the outer memo cell. No guest operation unwraps
// the Some box or retains its version list while we inspect the RC header.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const wasm = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const imports = {};
for (const { module, name } of WebAssembly.Module.imports(wasm)) {
  (imports[module] ??= {})[name] = () => {
    throw new Error(`unexpected host call ${module}.${name}`);
  };
}
const { main, test_ast_memo, memory } = new WebAssembly.Instance(wasm, imports).exports;
assert.equal(main(0n), 21n);
const cell = untag(test_ast_memo(0n));
const view = new DataView(memory.buffer);
const u32 = p => view.getUint32(p, true);
function untag(word) {
  assert.equal(word & 1n, 1n);
  return Number(word - 1n);
}
const pointer = p => untag(view.getBigUint64(p, true));
const map = pointer(u32(cell + 8)); // First element of the outer array.
const values = pointer(map + 16); // MutMap.vals is the second field.
const data = u32(values + 8);
const counts = [];
for (let i = 0; i < u32(values + 4); i++) {
  const box = pointer(data + i * 8);
  if (u32(box + 4) === 0) continue; // None
  assert.equal(u32(box + 4), 1);
  const versions = pointer(box + 8);
  assert.equal(u32(versions + 4), 1, "one source version for this path");
  counts.push(u32(versions - 4) & 0xffffff);
}
assert.deepEqual(counts, [1], "the memo must own the only version-list reference after all hits");
