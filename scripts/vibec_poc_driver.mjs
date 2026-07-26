#!/usr/bin/env node
// vibec browser PoC driver (#1107 Phase 5 / #857).
//
// Exercises the jco-transpiled vibec component end-to-end using ONLY
// browser-available APIs (ESM import, TextEncoder, WebAssembly.instantiate):
//   1. call `compile(source_hex_payload, "len-mode:<mode>:<entry>")`
//   2. fetch the compiled wasm back via "hex-chunk-mode:..." requests
//   3. instantiate the produced module with plain WebAssembly and run it.
// Everything here would run unchanged in a browser <script type="module">
// (swap the fs read of the sample for a fetch). Node is just the headless
// stand-in so this can be a repeatable script.
//
// usage: node scripts/vibec_poc_driver.mjs [transpiled-dir]

import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const dir = process.argv[2] || "_build/vibec/jco";
const entry = readdirSync(dir).find((f) => f.endsWith(".js"));
if (!entry) {
  console.error(`PoC FAIL: no transpiled .js module in ${dir}`);
  process.exit(1);
}
const mod = await import(pathToFileURL(`${dir}/${entry}`).href);
const compile = mod.compile;
if (typeof compile !== "function") {
  console.error("PoC FAIL: transpiled module does not export compile()");
  process.exit(1);
}

// Payload: hex("main_path \0 main_source") — single-file program.
const source = "let answer = () -> Int { 40 + 2 }\n";
const payload = `poc.vibe\u0000${source}`;
const hex = [...new TextEncoder().encode(payload)]
  .map((b) => b.toString(16).padStart(2, "0"))
  .join("");

const lenStr = compile(hex, "len-mode:mvp:answer");
const byteLen = parseInt(lenStr, 10);
if (!Number.isFinite(byteLen) || byteLen <= 8) {
  console.error(`PoC FAIL: len-mode returned '${lenStr}'`);
  process.exit(1);
}

const bytes = new Uint8Array(byteLen);
let off = 0;
for (let chunk = 0; off < byteLen; chunk++) {
  const hexChunk = compile(hex, `hex-chunk-mode:mvp:answer:${chunk}`);
  if (!hexChunk) {
    console.error(`PoC FAIL: empty chunk ${chunk} at offset ${off}`);
    process.exit(1);
  }
  for (let i = 0; i < hexChunk.length; i += 2) {
    bytes[off++] = parseInt(hexChunk.slice(i, i + 2), 16);
  }
}

// Compiled cores import wasi fd_write; capture what _start prints with it
// (in a browser this shim is identical — no WASI polyfill needed for pure
// programs).
let captured = "";
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: {
    fd_write: (fd, iovs, n, _written) => {
      const mem = new DataView(instance.exports.memory.buffer);
      for (let i = 0; i < n; i++) {
        const ptr = mem.getUint32(iovs + 8 * i, true);
        const len = mem.getUint32(iovs + 4 + 8 * i, true);
        captured += new TextDecoder().decode(
          new Uint8Array(instance.exports.memory.buffer, ptr, len),
        );
      }
      return 0;
    },
  },
});
// Exported user functions take a leading i64 closure-env param (0n when
// calling directly); _start wraps the requested entry and prints its result.
const direct = Number(instance.exports.answer(0n));
instance.exports._start();
if (direct !== 42 || captured.trim() !== "42") {
  console.error(
    `PoC FAIL: direct=${direct} stdout=${JSON.stringify(captured)} (expected 42)`,
  );
  process.exit(1);
}
console.log(
  `PoC OK: compiled ${source.trim().length}-char source to ${byteLen}B wasm fully in-memory; answer(0n) -> ${direct}, _start printed ${JSON.stringify(captured.trim())}`,
);
