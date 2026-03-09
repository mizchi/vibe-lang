#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

const TAG_MASK = 3n;
const TAG_INT = 0n;
const TAG_OBJ = 1n;

const OBJ_STRING = 1;
const OBJ_ARRAY = 5;

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

function writeU32LE(mem, pos, val) {
  mem[pos] = val & 0xff;
  mem[pos + 1] = (val >>> 8) & 0xff;
  mem[pos + 2] = (val >>> 16) & 0xff;
  mem[pos + 3] = (val >>> 24) & 0xff;
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
  if (ty !== OBJ_STRING) {
    throw new Error(`expected obj_string(${OBJ_STRING}), got ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const start = ptr + 8;
  const end = start + len;
  if (end > mem.length) {
    throw new Error(`string range out of bounds: ${start}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

// Allocate a tagged string in WASM linear memory.
// Requires __heap_ptr global to be exported.
function encodeTaggedString(instance, jsStr) {
  const heapGlobal = instance.exports.__heap_ptr;
  if (!heapGlobal) {
    throw new Error("__heap_ptr global not exported; cannot allocate string");
  }
  const encoded = new TextEncoder().encode(jsStr);
  const headerSize = 8; // 4 bytes type + 4 bytes length
  const totalSize = headerSize + encoded.length;
  const alignedSize = (totalSize + 7) & ~7; // align to 8 bytes

  // Ensure enough memory
  let mem = new Uint8Array(instance.exports.memory.buffer);
  const heapPtr = heapGlobal.value;
  const needed = heapPtr + alignedSize;
  if (needed > mem.length) {
    const pagesNeeded = Math.ceil((needed - mem.length) / 65536);
    instance.exports.memory.grow(pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }

  // Write string object: [type:i32=1][length:i32][utf8_data...]
  const ptr = heapPtr;
  writeU32LE(mem, ptr, OBJ_STRING);
  writeU32LE(mem, ptr + 4, encoded.length);
  mem.set(encoded, ptr + 8);

  // Advance heap pointer
  heapGlobal.value = ptr + alignedSize;

  // Return tagged pointer (tag = OBJ = 1)
  return BigInt(ptr) | TAG_OBJ;
}

// Decode a tagged Bytes (Array[Int]) from WASM memory into a Uint8Array.
// MoonBit WASM backend stores Array[Int] elements as tagged i32 at 4-byte stride.
// Layout: [type:i32=5][length:i32][elem0:i32][elem1:i32]...
// Each element is a tagged i32: (value << 2) | 0 for integers.
function decodeTaggedBytes(instance, tagged) {
  if (typeof tagged !== "bigint") {
    throw new Error(`expected tagged bytes bigint, got ${typeof tagged}`);
  }
  if ((tagged & TAG_MASK) !== TAG_OBJ) {
    throw new Error(`expected tagged bytes object, got tag=${tagged & TAG_MASK}`);
  }
  const ptr = Number(tagged & ~TAG_MASK);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const ty = readU32LE(mem, ptr);
  if (ty !== OBJ_ARRAY) {
    throw new Error(`expected obj_array(${OBJ_ARRAY}), got ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const result = new Uint8Array(len);
  const dataView = new DataView(instance.exports.memory.buffer);
  for (let i = 0; i < len; i++) {
    // Each element is a tagged i32 at offset 8 + i*4
    const elemOffset = ptr + 8 + i * 4;
    const taggedVal = dataView.getInt32(elemOffset, true);
    // Untag: (val >> 2) for integer tag
    result[i] = (taggedVal >> 2) & 0xff;
  }
  // Debug: dump first 16 raw tagged values and decoded bytes
  if (process.env.VIBE_DEBUG_BYTES === "1" && len > 0) {
    const debugN = Math.min(len, 16);
    const rawVals = [];
    const decodedVals = [];
    for (let i = 0; i < debugN; i++) {
      const off = ptr + 8 + i * 4;
      const tv = dataView.getInt32(off, true);
      rawVals.push(`0x${tv.toString(16).padStart(8, '0')}`);
      decodedVals.push(result[i]);
    }
    console.error(`[debug bytes] ptr=0x${ptr.toString(16)} ty=${ty} len=${len}`);
    console.error(`[debug bytes] raw[0..${debugN}]: ${rawVals.join(', ')}`);
    console.error(`[debug bytes] decoded[0..${debugN}]: ${decodedVals.join(', ')}`);
    console.error(`[debug bytes] expected WASM magic: 0, 97, 115, 109, 1, 0, 0, 0`);
  }
  return result;
}

function taggedIntToText(tagged) {
  if ((tagged & TAG_MASK) === TAG_INT) {
    return (tagged >> 2n).toString();
  }
  return tagged.toString();
}

function parseFuncToTableSlot(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  let pos = 8;
  const funcToSlot = {};
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    let sectionLen = 0;
    let shift = 0;
    while (true) {
      const b = buf[pos++];
      sectionLen |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) break;
      shift += 7;
    }
    const sectionEnd = pos + sectionLen;
    if (sectionId === 9) {
      let elemCount = 0;
      shift = 0;
      while (true) {
        const b = buf[pos++];
        elemCount |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7;
      }
      for (let i = 0; i < elemCount; i += 1) {
        const flags = buf[pos++];
        if (flags === 0) {
          if (buf[pos++] !== 0x41) {
            throw new Error("expected i32.const in elem section");
          }
          let tableOffset = 0;
          shift = 0;
          while (true) {
            const b = buf[pos++];
            tableOffset |= (b & 0x7f) << shift;
            if ((b & 0x80) === 0) break;
            shift += 7;
          }
          if (buf[pos++] !== 0x0b) {
            throw new Error("expected end in elem expr");
          }
          let numFuncs = 0;
          shift = 0;
          while (true) {
            const b = buf[pos++];
            numFuncs |= (b & 0x7f) << shift;
            if ((b & 0x80) === 0) break;
            shift += 7;
          }
          for (let j = 0; j < numFuncs; j += 1) {
            let funcIdx = 0;
            shift = 0;
            while (true) {
              const b = buf[pos++];
              funcIdx |= (b & 0x7f) << shift;
              if ((b & 0x80) === 0) break;
              shift += 7;
            }
            funcToSlot[funcIdx] = tableOffset + j;
          }
        } else {
          pos = sectionEnd;
          break;
        }
      }
    }
    pos = sectionEnd;
  }
  return funcToSlot;
}

function parseExportFuncIndices(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  let pos = 8;
  const exports = {};
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    let sectionLen = 0;
    let shift = 0;
    while (true) {
      const b = buf[pos++];
      sectionLen |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) break;
      shift += 7;
    }
    const sectionEnd = pos + sectionLen;
    if (sectionId === 7) {
      let count = 0;
      shift = 0;
      while (true) {
        const b = buf[pos++];
        count |= (b & 0x7f) << shift;
        if ((b & 0x80) === 0) break;
        shift += 7;
      }
      for (let i = 0; i < count; i += 1) {
        let nameLen = 0;
        shift = 0;
        while (true) {
          const b = buf[pos++];
          nameLen |= (b & 0x7f) << shift;
          if ((b & 0x80) === 0) break;
          shift += 7;
        }
        const name = buf.slice(pos, pos + nameLen).toString("utf8");
        pos += nameLen;
        const kind = buf[pos++];
        let idx = 0;
        shift = 0;
        while (true) {
          const b = buf[pos++];
          idx |= (b & 0x7f) << shift;
          if ((b & 0x80) === 0) break;
          shift += 7;
        }
        if (kind === 0) {
          exports[name] = idx;
        }
      }
    }
    pos = sectionEnd;
  }
  return exports;
}

function findClosureEnv(instance, heapStart, tableSlot) {
  const heapGlobal = instance.exports.__heap_ptr;
  if (!heapGlobal) {
    return 0;
  }
  const heapEnd = heapGlobal.value;
  const mem = new Uint8Array(instance.exports.memory.buffer);
  for (let ptr = heapStart; ptr < heapEnd; ptr += 8) {
    if (readU32LE(mem, ptr) === 7 && readU32LE(mem, ptr + 4) === tableSlot) {
      return ptr;
    }
  }
  return 0;
}

let instanceRefGlobal = null;

async function main() {
  const { invoke, wasmPath } = parseArgs(process.argv.slice(2));
  const wasmBytes = fs.readFileSync(wasmPath);
  const exportFuncIndices = parseExportFuncIndices(wasmBytes);
  const funcToTableSlot = parseFuncToTableSlot(wasmBytes);
  let instanceRef = null;
  // Also store globally for error handler (see catch block)

  const debugImports = process.env.VIBE_DEBUG_IMPORTS === "1";
  const fallbackModule = new Proxy(
    {},
    {
      get(_target, key) {
        return (...args) => {
          if (debugImports) {
            console.error(`[fallback import] unknown.${String(key)}(${args.length} args)`);
          }
          return 0n;
        };
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
      fs_read_file(pathTagged) {
        const filePath = decodeTaggedString(instanceRef, pathTagged);
        try {
          const content = fs.readFileSync(filePath, "utf8");
          return encodeTaggedString(instanceRef, content);
        } catch (e) {
          throw new Error(`fs_read_file failed for '${filePath}': ${e.message}`);
        }
      },
      fs_write_bytes(pathTagged, bytesTagged) {
        const filePath = decodeTaggedString(instanceRef, pathTagged);
        const bytes = decodeTaggedBytes(instanceRef, bytesTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(filePath, bytes);
        return 0n;
      },
      env_get(nameTagged) {
        const name = decodeTaggedString(instanceRef, nameTagged);
        const val = process.env[name] || "";
        return encodeTaggedString(instanceRef, val);
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

  const wasiModule = {
    fd_write(fd, iovs, iovsLen, nwritten) {
      // WASI fd_write: write iov buffers to fd (1=stdout, 2=stderr)
      const mem = new Uint8Array(instanceRef.exports.memory.buffer);
      const view = new DataView(instanceRef.exports.memory.buffer);
      let totalWritten = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        const bytes = mem.slice(ptr, ptr + len);
        const text = new TextDecoder().decode(bytes);
        if (fd === 1) {
          process.stdout.write(text);
        } else {
          process.stderr.write(text);
        }
        totalWritten += len;
      }
      view.setUint32(nwritten, totalWritten, true);
      return 0;
    },
  };

  const imports = new Proxy(
    { vibe: vibeModule, wasi_snapshot_preview1: wasiModule },
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
  instanceRefGlobal = instance;

  const fn = instance.exports[invoke];
  if (typeof fn !== "function") {
    throw new Error(`missing export: ${invoke}`);
  }

  // User-exported functions have an implicit i32 env parameter (closure ABI).
  // The "run" entry has no params; all other exports take (i32) -> i64.
  // For closure exports, resolve the real env pointer from the initialized heap.
  if (invoke !== "run" && typeof instance.exports.run === "function") {
    const initHeap =
      instance.exports.__heap_ptr instanceof WebAssembly.Global
        ? instance.exports.__heap_ptr.value
        : 0;
    instance.exports.run();
    const funcIdx = exportFuncIndices[invoke];
    const tableSlot = funcIdx !== undefined ? funcToTableSlot[funcIdx] : undefined;
    var resolvedEnv =
      tableSlot !== undefined ? findClosureEnv(instance, initHeap, tableSlot) : 0;
  } else {
    var resolvedEnv = 0;
  }
  let result;
  let isSelfhost = false;
  try {
    // Try i32 ABI first, then i64 ABI used by selfhost-compiled exports.
    if (invoke === "run") {
      result = fn();
    } else {
      try {
        result = fn(resolvedEnv);
      } catch (typeErr) {
        if (typeErr instanceof TypeError) {
          result = fn(BigInt(resolvedEnv));
          isSelfhost = true;
        } else {
          throw typeErr;
        }
      }
    }
  } catch (err) {
    // Dump heap state on crash
    const heapGlobal = instance.exports.__heap_ptr;
    const mem = new Uint8Array(instance.exports.memory.buffer);
    const hp = heapGlobal?.value;
    console.error(`[crash debug] heap_ptr=${hp} (0x${hp?.toString(16)}), memory_size=${mem.length} (${(mem.length / 65536)} pages)`);
    // Dump first few bytes and around heap pointer
    const dv = new DataView(instance.exports.memory.buffer);
    console.error(`[crash debug] mem[0..32]: ${Array.from(mem.slice(0, 32)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
    if (hp && hp < mem.length - 32) {
      console.error(`[crash debug] mem[heap-8..heap+24]: ${Array.from(mem.slice(hp - 8, hp + 24)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
    }
    throw err;
  }
  if (typeof result === "bigint") {
    // Check if the result is a tagged object (could be Bytes from selfbuild)
    if (
      (result & TAG_MASK) === TAG_OBJ &&
      invoke === "selfbuild_compile_stage2"
    ) {
      // Decode result as Bytes and write to expected output path
      const bytes = decodeTaggedBytes(instanceRef, result);
      const outPath =
        "_build/bench/selfhost_wasi_selfbuild/index_stage2.wasm";
      const outDir = path.dirname(outPath);
      if (!fs.existsSync(outDir)) {
        fs.mkdirSync(outDir, { recursive: true });
      }
      fs.writeFileSync(outPath, bytes);
      console.log(`wrote ${outPath} (${bytes.length} bytes)`);
    } else if (isSelfhost) {
      // Selfhost-compiled modules return untagged i64 values — print as-is.
      console.log(result.toString());
    } else {
      console.log(taggedIntToText(result));
    }
  } else if (result !== undefined) {
    console.log(String(result));
  }
}

main().catch((err) => {
  // Try to decode WASM exception payload (tagged string)
  if (err instanceof WebAssembly.Exception) {
    try {
      // The exception tag exports a single i64 payload
      const tag = instanceRefGlobal?.exports?.__error_tag;
      if (tag) {
        const payload = err.getArg(tag, 0);
        if (typeof payload === "bigint" && (payload & TAG_MASK) === TAG_OBJ) {
          const msg = decodeTaggedString(instanceRefGlobal, payload);
          console.error(`Error string: ${msg}`);
          process.exit(1);
        }
      }
    } catch (_) {}
    // Fallback: try all exported tags
    try {
      if (instanceRefGlobal) {
        for (const [name, exp] of Object.entries(instanceRefGlobal.exports)) {
          if (exp instanceof WebAssembly.Tag) {
            try {
              const payload = err.getArg(exp, 0);
              if (typeof payload === "bigint" && (payload & TAG_MASK) === TAG_OBJ) {
                const msg = decodeTaggedString(instanceRefGlobal, payload);
                console.error(`Error string (tag=${name}): ${msg}`);
                process.exit(1);
              }
              // Try to decode as tagged int
              if (typeof payload === "bigint" && (payload & TAG_MASK) === TAG_INT) {
                const intVal = Number(payload >> 2n);
                console.error(`Exception payload (tag=${name}): tagged int ${intVal} (raw=${payload})`);
              } else {
                console.error(`Exception payload (tag=${name}): ${payload}`);
              }
              // Also try to brute-force decode nearby memory as string
              if (typeof payload === "bigint" && instanceRefGlobal?.exports?.memory) {
                const mem = new Uint8Array(instanceRefGlobal.exports.memory.buffer);
                for (const tryPtr of [Number(payload), Number(payload & ~TAG_MASK), Number(payload >> 2n)]) {
                  if (tryPtr > 0 && tryPtr + 8 < mem.length) {
                    const ty = readU32LE(mem, tryPtr);
                    if (ty === OBJ_STRING) {
                      const len = readU32LE(mem, tryPtr + 4);
                      if (len > 0 && len < 10000 && tryPtr + 8 + len <= mem.length) {
                        const str = new TextDecoder().decode(mem.subarray(tryPtr + 8, tryPtr + 8 + len));
                        console.error(`  -> string at ptr=${tryPtr}: "${str}"`);
                      }
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
  usage();
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
