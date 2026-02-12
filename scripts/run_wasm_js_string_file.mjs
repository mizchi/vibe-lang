#!/usr/bin/env node
import { readFile } from "node:fs/promises";

function usage() {
  console.log("usage: node scripts/run_wasm_js_string_file.mjs <file.wasm>");
}

const args = process.argv.slice(2);
if (args.length !== 1) {
  usage();
  process.exit(1);
}

const wasmPath = args[0];

const importObject = {
  vibe: {
    path: (value) => value,
    sh: (_value) => 0,
  },
};

const compileOptions = {
  builtins: ["js-string"],
  importedStringConstants: "string_constants",
};

try {
  const bytes = await readFile(wasmPath);
  const mod = await WebAssembly.compile(bytes, compileOptions);
  const instance = await WebAssembly.instantiate(mod, importObject);
  const result = instance.exports.run();
  if (process.env.VIBE_WASM_PRINT_RESULT === "1") {
    console.log("run:", result);
  }
} catch (err) {
  console.error("failed to run wasm with js-string builtins:");
  console.error(err?.message ?? err);
  process.exit(1);
}
