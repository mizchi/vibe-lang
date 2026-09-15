// Invoked by array_capacity_lowering_test.vibe with its freshly compiled GC module.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const imports = { wasi_snapshot_preview1: { fd_write: () => 0 } };
async function run(n) {
  const module = await WebAssembly.compile(readFileSync(`${process.argv[2]}${n}.wasm`));
  const { exports } = await WebAssembly.instantiate(module, imports);
  const before = exports.__heap_ptr.value;
  const result = exports.main(0n);
  assert.equal(result, BigInt(n));
  return exports.__heap_ptr.value - before;
}
const empty = await run(0);
assert.equal(empty, 12 + 4096 * 8);
assert.equal(await run(4096), empty);
assert.ok(await run(4097) > empty);
console.log("ok");
