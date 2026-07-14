// Throughput + peak-heap benchmark for selfhost-compiled wasm (ADR-0055 Stage 5).
//
// Times a single call to `main` (which runs an allocation-heavy loop of N
// iterations internally) and reads the bump pointer `__heap_ptr` for peak heap.
// A FRESH instance is created for every timed repeat so the default (no-RC) bump
// allocator does not accumulate heap across repeats — making default vs RC a
// fair comparison: RC reuses blocks (bounded heap) while default grows linearly.
//
// Usage:
//   node scripts/bench_rc.mjs <module.wasm> [invoke=main] [repeats=7] [args...]
// Prints one JSON line: { median_ms, min_ms, heap_used }.

import fs from "node:fs";

const [, , wasmPath, invoke = "main", repeatsRaw = "7", ...rawArgs] = process.argv;
if (!wasmPath) {
  console.error("usage: node bench_rc.mjs <module.wasm> [invoke] [repeats] [args...]");
  process.exit(2);
}
const repeats = Number(repeatsRaw);

const buf = fs.readFileSync(wasmPath);
const mod = await WebAssembly.compile(buf);

function freshInstance() {
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
  return new WebAssembly.Instance(mod, importObject);
}

const envAndArgs = [0n, ...rawArgs.map((a) => BigInt(a))];

let heapUsed = 0;
const times = [];
// One warm-up to let the JIT compile the wasm body, then `repeats` timed runs.
for (let r = -1; r < repeats; r++) {
  const instance = freshInstance();
  const heapGlobal = instance.exports.__heap_ptr;
  const fn = instance.exports[invoke];
  if (typeof fn !== "function") {
    console.error(`module does not export function ${invoke}`);
    process.exit(4);
  }
  const before = Number(heapGlobal.value);
  const t0 = process.hrtime.bigint();
  fn(...envAndArgs.slice(0, fn.length));
  const t1 = process.hrtime.bigint();
  const after = Number(heapGlobal.value);
  if (r >= 0) {
    times.push(Number(t1 - t0) / 1e6);
    heapUsed = after - before;
  }
}

times.sort((a, b) => a - b);
const median = times[Math.floor(times.length / 2)];
console.log(
  JSON.stringify({
    median_ms: Number(median.toFixed(4)),
    min_ms: Number(times[0].toFixed(4)),
    heap_used: heapUsed,
  }),
);
