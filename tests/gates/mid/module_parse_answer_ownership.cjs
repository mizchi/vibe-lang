// The provider holds one reference to each returned array. Read the RC headers
// from the host so the assertions themselves never retain a guest reference.
const fs = require("node:fs");
const assert = require("node:assert/strict");
const wasm = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const imports = {};
for (const { module, name } of WebAssembly.Module.imports(wasm)) {
  (imports[module] ??= {})[name] = () => { throw new Error(`unexpected host call ${module}.${name}`); };
}
const { main, memory } = new WebAssembly.Instance(wasm, imports).exports;
const answers = 2 * Number(main(0n));
const view = new DataView(memory.buffer);
const u32 = address => view.getUint32(address, true);
assert.equal(u32(answers + 4), 21);
const data = u32(answers + 8);
for (let i = 0; i < 21; i++) {
  const tagged = view.getBigUint64(data + 8 * i, true);
  assert.equal(tagged & 1n, 1n);
  const array = Number(tagged - 1n);
  assert.equal(u32(array + 4), 1);
  assert.equal(u32(array - 4) & 0xffffff, 1, `unexpected owner count for parse answer ${i}`);
}
