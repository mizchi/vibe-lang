#!/usr/bin/env node
// vibec-hosted PoC driver (#1109-2 / #857): drive the jco-transpiled HOSTED
// vibec component, whose filesystem is the WIT-imported vfs interface —
// here an in-memory map, exactly what a browser IDE would provide. Compiles
// a MULTI-FILE program (main imports ./lib.vibe) purely through vfs
// callbacks, then instantiates and runs the produced wasm.
//
// usage: node scripts/vibec_hosted_poc_driver.mjs [transpiled-dir]
//   (transpile with: jco transpile vibec.hosted.component.wasm
//      -o <dir> --no-wasi-shim --instantiation async)

import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const dir = process.argv[2] || "_build/vibec/jco_hosted";
const entry = readdirSync(dir).find((f) => f.endsWith(".js"));
if (!entry) {
  console.error(`PoC FAIL: no transpiled .js module in ${dir}`);
  process.exit(1);
}
const { instantiate } = await import(pathToFileURL(`${dir}/${entry}`).href);

// --- the host's virtual filesystem (what a browser would keep in memory) ---
const files = new Map([
  [
    "main.vibe",
    'import ./lib.vibe { helper }\nexport let answer = () -> Int { helper() }\n',
  ],
  ["lib.vibe", "export let helper = () -> Int { 40 + 2 }\n"],
]);
const norm = (p) => p.replace(/^\.\//, "");
const calls = { readFile: 0, exists: 0, readDir: 0, statToken: 0 };
const vfs = {
  "read-file": {
    default(path) {
      calls.readFile++;
      const f = files.get(norm(path));
      if (f === undefined) throw new Error(`vfs: no such file: ${path}`);
      return f;
    },
  },
  exists: {
    default(path) {
      calls.exists++;
      return files.has(norm(path));
    },
  },
  "read-dir": {
    default(path) {
      calls.readDir++;
      const prefix = norm(path) === "." ? "" : norm(path) + "/";
      const names = [...files.keys()]
        .filter((k) => k.startsWith(prefix))
        .map((k) => k.slice(prefix.length).split("/")[0]);
      return [...new Set(names)].sort().join("\n");
    },
  },
  "stat-token": {
    default(path) {
      calls.statToken++;
      const f = files.get(norm(path));
      // Any stable value works; -1n is the reserved non-regular witness.
      return f === undefined ? -1n : BigInt(f.length);
    },
  },
};

// The component has six core modules (main / trampoline / stub / shim /
// realloc / adapter); jco asks for each by filename.
const root = await instantiate(
  (path) => WebAssembly.compile(readFileSync(`${dir}/${path}`)),
  vfs,
);

const lenStr = root.compileFile("main.vibe", "len-mode:mvp:answer");
const byteLen = parseInt(lenStr, 10);
if (!Number.isFinite(byteLen) || byteLen <= 8) {
  console.error(`PoC FAIL: len-mode returned '${lenStr}' (vfs calls: ${JSON.stringify(calls)})`);
  process.exit(1);
}
const bytes = new Uint8Array(byteLen);
let off = 0;
for (let chunk = 0; off < byteLen; chunk++) {
  const hexChunk = root.compileFile("main.vibe", `hex-chunk-mode:mvp:answer:${chunk}`);
  if (!hexChunk) {
    console.error(`PoC FAIL: empty chunk ${chunk} at offset ${off}`);
    process.exit(1);
  }
  for (let i = 0; i < hexChunk.length; i += 2) {
    bytes[off++] = parseInt(hexChunk.slice(i, i + 2), 16);
  }
}

const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: { fd_write: () => 0 },
});
const result = Number(instance.exports.answer(0n));
if (result !== 42) {
  console.error(`PoC FAIL: compiled program returned ${result}, expected 42`);
  process.exit(1);
}
console.log(
  `PoC OK: multi-file compile through the vfs interface (${calls.readFile} reads, ${calls.exists} exists, ${calls.readDir} readdirs, ${calls.statToken} stats) -> ${byteLen}B wasm -> answer(0n) = ${result}`,
);
