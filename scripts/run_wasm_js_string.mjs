#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFile, mkdir } from "node:fs/promises";
import path from "node:path";

function usage() {
  console.log("usage: node scripts/run_wasm_js_string.mjs <file.vibe> [--out wasm]");
}

const args = process.argv.slice(2);
if (args.length === 0) {
  usage();
  process.exit(1);
}

let entry = null;
let outPath = null;
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--out") {
    if (i + 1 >= args.length) {
      console.error("--out requires a path");
      process.exit(1);
    }
    outPath = args[i + 1];
    i += 1;
  } else if (entry === null) {
    entry = arg;
  } else {
    console.error("too many args");
    process.exit(1);
  }
}

if (entry === null) {
  usage();
  process.exit(1);
}

if (outPath === null) {
  const dir = path.join(process.cwd(), "target");
  await mkdir(dir, { recursive: true });
  outPath = path.join(dir, "xsh_js_string.wasm");
}

function compileWasm(flag, output) {
  const args = [
    "run",
    "src/cmd/xsh/main.mbt",
    "--target",
    "native",
    "--",
    "compile",
    flag,
    "-o",
    output,
    entry,
  ];
  const compile = spawnSync("moon", args, { stdio: "inherit" });
  if (compile.status !== 0) {
    throw new Error(`compile failed (${flag})`);
  }
}

async function runWasm(bytes, options) {
  const mod = options
    ? await WebAssembly.compile(bytes, options)
    : await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(mod, importObject);
  return instance.exports.run();
}
const importObject = {
  xsh: {
    path: (value) => value,
    sh: (_value) => 0,
  },
};
const compileOptions = {
  builtins: ["js-string"],
  importedStringConstants: "string_constants",
};

try {
  compileWasm("--wasm-js-string", outPath);
  const bytes = await readFile(outPath);
  const result = await runWasm(bytes, compileOptions);
  console.log("run:", result);
} catch (err) {
  console.error("failed to run wasm with js-string builtins:");
  console.error(err?.message ?? err);
  console.error(
    "Your JS engine may not support js-string builtins or imported string constants yet.",
  );
  try {
    const fallbackPath = outPath.replace(/\\.wasm$/, "") + "_plain.wasm";
    compileWasm("--wasm", fallbackPath);
    const bytes = await readFile(fallbackPath);
    const result = await runWasm(bytes, null);
    console.log("run (fallback --wasm):", result);
  } catch (fallbackErr) {
    console.error("fallback --wasm run failed:");
    console.error(fallbackErr?.message ?? fallbackErr);
    process.exit(1);
  }
}
