// Read the headers after the guest returns so the probe adds no owners.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const wasm = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const imports = {};
for (const { module, name } of WebAssembly.Module.imports(wasm)) {
  (imports[module] ??= {})[name] = () => {
    throw new Error(`unexpected host call ${module}.${name}`);
  };
}
const { main, memory } = new WebAssembly.Instance(wasm, imports).exports;
const result = 2 * Number(main(0n));
const view = new DataView(memory.buffer);
const u32 = address => view.getUint32(address, true);
const owners = address => u32(address - 4) & 0xffffff;
function items(array, length) {
  assert.equal(u32(array + 4), length);
  const data = u32(array + 8);
  return Array.from({ length }, (_, i) => {
    const value = view.getBigUint64(data + 8 * i, true);
    assert.equal(value & 1n, 1n);
    return Number(value - 1n);
  });
}
const [released, original, rebuilt] = items(result, 3).map(array => items(array, 2));
assert.equal(owners(released[0]), 1, "discarded results release the original let");
assert.equal(owners(released[1]), 1, "discarded results release the shared enum");
assert.notEqual(original[0], rebuilt[0], "the rewrite builds a new let");
assert.equal(owners(original[0]), 1, "repeated rewrites release the original let");
assert.equal(owners(rebuilt[0]), 1, "the result owns the rebuilt let");
assert.equal(original[1], rebuilt[1], "both arrays contain the unchanged enum");
assert.equal(owners(original[1]), 2, "each live array owns the enum");
