// Measure heap usage of a selfhost-compiled wasm module.
//
// The selfhost linear backend bump-allocates from a single i32 global exported
// as `__heap_ptr`. Reading it before/after invoking a function gives the number
// of bytes allocated during the call. With the bump allocator (no reclamation)
// this grows with the work done — so for an allocating loop it scales with the
// iteration count, which is exactly the leak. Once Perceus RC + a free-list
// land (Phase 3), the same measurement should stay bounded.
//
// Usage: node scripts/measure_selfhost_heap.mjs <module.wasm> [invoke=main] [args...]
// Prints one JSON line: { result, heap_before, heap_after, heap_used }.

import fs from "node:fs";

const [, , wasmPath, invoke = "main", ...rawArgs] = process.argv;
if (!wasmPath) {
  console.error("usage: node measure_selfhost_heap.mjs <module.wasm> [invoke] [args...]");
  process.exit(2);
}

const buf = fs.readFileSync(wasmPath);
const mod = await WebAssembly.compile(buf);

// Stub every imported function as a no-op returning 0 so any pure module
// instantiates without a real WASI host (these heap programs do no real I/O).
const importObject = {};
for (const imp of WebAssembly.Module.imports(mod)) {
  importObject[imp.module] ??= {};
  if (imp.kind === "function") {
    importObject[imp.module][imp.name] = () => 0;
  } else if (imp.kind === "memory") {
    importObject[imp.module][imp.name] = new WebAssembly.Memory({ initial: 16 });
  } else if (imp.kind === "global") {
    importObject[imp.module][imp.name] = new WebAssembly.Global(
      { value: "i32", mutable: true },
      0,
    );
  }
}

const instance = await WebAssembly.instantiate(mod, importObject);
const heapGlobal = instance.exports.__heap_ptr;
if (!heapGlobal) {
  console.error("module does not export __heap_ptr");
  process.exit(3);
}

const fn = instance.exports[invoke];
if (typeof fn !== "function") {
  console.error(`module does not export function ${invoke}`);
  process.exit(4);
}

const before = Number(heapGlobal.value);
// The selfhost calling convention passes a closure-env pointer as the first
// argument and uses tagged i64 for all values, so call with env=0 then the
// (BigInt) args, trimmed to the export's arity.
const envAndArgs = [0n, ...rawArgs.map((a) => BigInt(a))];
const result = fn(...envAndArgs.slice(0, fn.length));
const after = Number(heapGlobal.value);

console.log(
  JSON.stringify({
    result: Number(result),
    heap_before: before,
    heap_after: after,
    heap_used: after - before,
  }),
);
