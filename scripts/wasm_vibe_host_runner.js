#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const cp = require("node:child_process");

const TAG_MASK = 3n;
const TAG_OBJ = 1n;

function usage() {
  console.error(
    "usage: node scripts/wasm_vibe_host_runner.js [--invoke <name>] <module.wasm>",
  );
}

function parseArgs(argv) {
  let invoke = "run";
  let wasmPath = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--invoke") {
      if (i + 1 >= argv.length) {
        throw new Error("--invoke requires function name");
      }
      invoke = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg.startsWith("-")) {
      throw new Error(`unknown option: ${arg}`);
    }
    if (wasmPath !== null) {
      throw new Error(`unexpected argument: ${arg}`);
    }
    wasmPath = arg;
  }
  if (wasmPath === null) {
    throw new Error("missing wasm path");
  }
  return { invoke, wasmPath };
}

function readU32LE(mem, pos) {
  if (pos < 0 || pos + 4 > mem.length) {
    throw new Error(`memory read out of bounds at ${pos}`);
  }
  return (
    mem[pos] |
    (mem[pos + 1] << 8) |
    (mem[pos + 2] << 16) |
    (mem[pos + 3] << 24)
  ) >>> 0;
}

function decodeTaggedString(instance, tagged) {
  if (typeof tagged !== "bigint") {
    throw new Error(`expected tagged string bigint, got ${typeof tagged}`);
  }
  if ((tagged & TAG_MASK) !== TAG_OBJ) {
    throw new Error(`expected tagged string object, got tag=${tagged & TAG_MASK}`);
  }
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for tagged string decode");
  }
  const ptr = Number(tagged & ~TAG_MASK);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const ty = readU32LE(mem, ptr);
  if (ty !== 1) {
    throw new Error(`expected obj_string(1), got ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const start = ptr + 8;
  const end = start + len;
  if (end > mem.length) {
    throw new Error(`string range out of bounds: ${start}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

function taggedIntToText(tagged) {
  if ((tagged & TAG_MASK) === 0n) {
    return (tagged >> 2n).toString();
  }
  return tagged.toString();
}

async function main() {
  const { invoke, wasmPath } = parseArgs(process.argv.slice(2));
  const wasmBytes = fs.readFileSync(wasmPath);
  let instanceRef = null;

  const fallbackModule = new Proxy(
    {},
    {
      get() {
        return () => 0n;
      },
    },
  );

  const vibeModule = new Proxy(
    {
      sh(cmdTagged) {
        const cmd = decodeTaggedString(instanceRef, cmdTagged);
        cp.execSync(cmd, { stdio: "inherit", shell: "/bin/bash" });
        return 0n;
      },
    },
    {
      get(target, key) {
        if (key in target) {
          return target[key];
        }
        return () => 0n;
      },
    },
  );

  const imports = new Proxy(
    { vibe: vibeModule },
    {
      get(target, key) {
        if (key in target) {
          return target[key];
        }
        return fallbackModule;
      },
    },
  );

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  instanceRef = instance;

  const fn = instance.exports[invoke];
  if (typeof fn !== "function") {
    throw new Error(`missing export: ${invoke}`);
  }

  const result = fn();
  if (typeof result === "bigint") {
    console.log(taggedIntToText(result));
  } else if (result !== undefined) {
    console.log(String(result));
  }
}

main().catch((err) => {
  usage();
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
