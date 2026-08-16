#!/usr/bin/env node
// Declared-local counts per function body of a wasm module.
//
// The code section declares locals as (count, valtype) runs, so "how many
// locals does this function frame have" is not visible in the module's byte
// size and not answerable with grep. #1985 needs exactly that number: the gc
// lane used to allocate a fresh slot per branch arm per nesting level, which
// grows as 2^depth and is invisible in a size comparison against the linear
// lane (whose fixed prelude differs by more than the regression does).
//
// Usage:
//   node scripts/wasm_local_counts.mjs <file.wasm>          # JSON summary
//   node scripts/wasm_local_counts.mjs --max <file.wasm>    # largest body only
//
// Counts SLOTS, not declaration entries, and does not include parameters --
// the same thing the code section's own local vector describes.
import fs from "node:fs";

const args = process.argv.slice(2);
const maxOnly = args[0] === "--max";
const path = maxOnly ? args[1] : args[0];
if (!path) {
  console.error("usage: wasm_local_counts.mjs [--max] <file.wasm>");
  process.exit(2);
}

const buf = fs.readFileSync(path);
let p = 8; // magic + version
function u32() {
  let r = 0, s = 0, b;
  do { b = buf[p++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80);
  return r >>> 0;
}

const counts = [];
while (p < buf.length) {
  const id = buf[p++];
  const size = u32();
  const sectionEnd = p + size;
  if (id === 10) {
    const bodies = u32();
    for (let i = 0; i < bodies; i++) {
      // Two statements: `p + u32()` would read `p` before u32() advances it.
      const bodySize = u32();
      const bodyEnd = p + bodySize;
      const runs = u32();
      let slots = 0;
      for (let r = 0; r < runs; r++) {
        slots += u32();
        // A reference type is the 0x63/0x64 prefix plus a type index.
        const valtype = buf[p++];
        if (valtype === 0x63 || valtype === 0x64) u32();
      }
      counts.push(slots);
      p = bodyEnd;
    }
  }
  p = sectionEnd;
}

counts.sort((a, b) => b - a);
if (maxOnly) {
  console.log(counts.length ? counts[0] : 0);
} else {
  console.log(JSON.stringify({
    bodies: counts.length,
    max: counts.length ? counts[0] : 0,
    top5: counts.slice(0, 5),
    sum: counts.reduce((a, b) => a + b, 0),
  }));
}
