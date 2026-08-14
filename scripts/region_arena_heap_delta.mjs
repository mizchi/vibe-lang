// ADR-0090 (#1262): report how much MAIN bump heap a wasm module's `_start`
// consumes, by reading the exported `__heap_ptr` global before and after.
//
// This is the arena's only honest observation point. The region fixtures all
// assert their VALUES, and a region that quietly stopped releasing still
// computes the right value -- the only thing that changes is how much memory
// it leaked. Prints one integer (the delta in bytes) to stdout.
import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: region_arena_heap_delta.mjs <module.wasm>");
  process.exit(2);
}
const mod = await WebAssembly.compile(readFileSync(path));
// The fixtures this runs on are pure compute, but a module can still carry
// host imports it never calls (the entry shim). Stub every import rather than
// requiring the caller to know which ones exist.
const imports = {};
for (const im of WebAssembly.Module.imports(mod)) {
  imports[im.module] = imports[im.module] || {};
  if (im.kind === "function") {
    imports[im.module][im.name] = () => 0;
  }
}
const inst = await WebAssembly.instantiate(mod, imports);
if (!(inst.exports.__heap_ptr instanceof WebAssembly.Global)) {
  console.error("module does not export __heap_ptr");
  process.exit(2);
}
const before = Number(inst.exports.__heap_ptr.value);
inst.exports._start();
console.log(String(Number(inst.exports.__heap_ptr.value) - before));
