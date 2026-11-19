// The fixture keeps one reference to each returned array. Inspect from the host
// so the assertions themselves never retain a guest reference.
const fs = require("node:fs");
const assert = require("node:assert/strict");
const wasm = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const expected = Number(process.argv[3]);
assert(Number.isSafeInteger(expected) && expected > 0);
const imports = {};
const emptyEnv = process.argv[4] === "--empty-env";
for (const { module, name } of WebAssembly.Module.imports(wasm)) {
  imports[module] ??= {};
  imports[module][name] = () => {
    if (emptyEnv && module === "vibe" && name === "env-get") return 0n; // Unset raw-ABI string.
    throw new Error(`unexpected host call ${module}.${name}`);
  };
}
const { main, memory, merge_answers } = new WebAssembly.Instance(wasm, imports).exports;
const answers = 2 * Number(main(0n));
const view = new DataView(memory.buffer);
const u32 = address => view.getUint32(address, true);
assert.equal(u32(answers + 4), expected);
const data = u32(answers + 8);
const distinct = new Set();
for (let i = 0; i < expected; i++) {
  const tagged = view.getBigUint64(data + 8 * i, true);
  assert.equal(tagged & 1n, 1n);
  const array = Number(tagged - 1n);
  distinct.add(array);
  assert.equal(u32(array + 4), 1);
  assert.equal(u32(array - 4) & 0xffffff, 1, `unexpected owner count for parse answer ${i}`);
}
assert.equal(distinct.size, expected, "each parse hands out its own outer array");

if (process.argv.includes("--check-merge")) {
  const held = new DataView(merge_answers.buffer);
  assert.equal(held.getUint32(0, true), 4, "two files in both merge modes");
  for (let i = 0; i < 4; i++) {
    const tagged = held.getUint32(4 + 4 * i, true);
    assert.equal(tagged & 1, 1);
    const array = tagged - 1;
    assert.equal(u32(array + 4), 1);
    assert.equal(u32(array - 4) & 0xffffff, 1, `merge still owns parse answer ${i}`);
  }
}
