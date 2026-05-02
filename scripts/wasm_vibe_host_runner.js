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
const OBJ_BYTES = 13;
const OBJ_BYTES_VIEW = 14;

function usage() {
  console.error(
    "usage: node scripts/wasm_vibe_host_runner.js [--invoke <name>] [--bench-count <n> --bench-warmup <n> --bench-setup <name>] <module.wasm> [argv...]",
  );
}

function parseArgs(argv) {
  const invokes = [];
  let wasmPath = null;
  const passthroughArgs = [];
  let benchCount = null;
  let benchWarmup = 0;
  let benchSetup = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--invoke") {
      if (i + 1 >= argv.length) {
        throw new Error("--invoke requires function name");
      }
      invokes.push(argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--bench-count") {
      if (i + 1 >= argv.length) {
        throw new Error("--bench-count requires integer value");
      }
      benchCount = Number.parseInt(argv[i + 1], 10);
      if (!Number.isFinite(benchCount) || benchCount <= 0) {
        throw new Error(`invalid --bench-count: ${argv[i + 1]}`);
      }
      i += 1;
      continue;
    }
    if (arg === "--bench-warmup") {
      if (i + 1 >= argv.length) {
        throw new Error("--bench-warmup requires integer value");
      }
      benchWarmup = Number.parseInt(argv[i + 1], 10);
      if (!Number.isFinite(benchWarmup) || benchWarmup < 0) {
        throw new Error(`invalid --bench-warmup: ${argv[i + 1]}`);
      }
      i += 1;
      continue;
    }
    if (arg === "--bench-setup") {
      if (i + 1 >= argv.length) {
        throw new Error("--bench-setup requires function name");
      }
      benchSetup = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg.startsWith("-")) {
      throw new Error(`unknown option: ${arg}`);
    }
    if (wasmPath !== null) {
      passthroughArgs.push(arg);
      continue;
    }
    wasmPath = arg;
  }
  if (wasmPath === null) {
    throw new Error("missing wasm path");
  }
  if (invokes.length === 0) {
    invokes.push("_start");
  }
  return { invokes, wasmPath, passthroughArgs, benchCount, benchWarmup, benchSetup };
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

function writeU64LE(mem, pos, val) {
  let next = BigInt.asUintN(64, BigInt(val));
  for (let i = 0; i < 8; i += 1) {
    mem[pos + i] = Number(next & 0xffn);
    next >>= 8n;
  }
}

function writeU8(mem, pos, val) {
  mem[pos] = val & 0xff;
}

function decodeUtf8Range(instance, ptr, len) {
  const mem = new Uint8Array(instance.exports.memory.buffer);
  if (ptr < 0 || len < 0 || ptr + len > mem.length) {
    throw new Error(`utf8 range out of bounds: ${ptr}..${ptr + len}`);
  }
  return new TextDecoder().decode(mem.subarray(ptr, ptr + len));
}

function allocPreview2Buffer(instance, size, align = 4) {
  if (typeof instance.exports.cabi_realloc === "function") {
    return instance.exports.cabi_realloc(0, 0, align, size) >>> 0;
  }
  const heapGlobal = instance.exports.__heap_ptr;
  if (!heapGlobal) {
    throw new Error("missing cabi_realloc/__heap_ptr for Preview2 allocation");
  }
  let mem = new Uint8Array(instance.exports.memory.buffer);
  const alignedPtr = (heapGlobal.value + (align - 1)) & ~(align - 1);
  const heapAlign = Math.max(align, 4);
  const next = (alignedPtr + size + (heapAlign - 1)) & ~(heapAlign - 1);
  if (next > mem.length) {
    const pagesNeeded = Math.ceil((next - mem.length) / 65536);
    instance.exports.memory.grow(pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }
  heapGlobal.value = next;
  return alignedPtr;
}

let hostAllocPtrGlobal = null;

function allocHostBuffer(instance, size, align = 8) {
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for host allocation");
  }
  let mem = new Uint8Array(instance.exports.memory.buffer);
  if (hostAllocPtrGlobal === null) {
    hostAllocPtrGlobal = mem.length;
  }
  let alignedPtr = (hostAllocPtrGlobal + (align - 1)) & ~(align - 1);
  let next = alignedPtr + size;
  if (next > mem.length) {
    const pagesNeeded = Math.ceil((next - mem.length) / 65536);
    instance.exports.memory.grow(pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }
  hostAllocPtrGlobal = next;
  return alignedPtr;
}

function decodeTaggedString(instance, tagged) {
  if (typeof tagged !== "bigint") {
    throw new Error(`expected tagged string bigint, got ${typeof tagged}`);
  }
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for tagged string decode");
  }
  const mem = new Uint8Array(instance.exports.memory.buffer);

  if ((tagged & TAG_MASK) === TAG_OBJ) {
    const ptr = Number(tagged & ~TAG_MASK);
    const ty = readU32LE(mem, ptr);
    if (ty === OBJ_STRING) {
      const len = readU32LE(mem, ptr + 4);
      const start = ptr + 8;
      const end = start + len;
      if (end > mem.length) {
        throw new Error(`string range out of bounds: ${start}..${end}`);
      }
      return new TextDecoder().decode(mem.subarray(start, end));
    }
  }

  const ptr = Number(tagged >> 32n);
  const len = Number(tagged & 0xffffffffn);
  const start = ptr;
  const end = start + len;
  if (start < 0 || end < start) {
    throw new Error(`invalid string ref: ptr=${ptr} len=${len}`);
  }
  if (end > mem.length) {
    throw new Error(`string range out of bounds: ${start}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

function decodeSelfhostPackedString(instance, packed) {
  if (typeof packed !== "bigint") {
    throw new Error(`expected selfhost packed string bigint, got ${typeof packed}`);
  }
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for selfhost string decode");
  }
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const ptr = Number(packed >> 32n);
  const len = Number(packed & 0xffffffffn);
  const start = ptr;
  const end = start + len;
  if (start < 0 || len < 0 || end < start || end > mem.length) {
    throw new Error(`selfhost string range out of bounds: ${start}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

function tryDecodeExceptionString(instance, payload) {
  if (!instance || typeof payload !== "bigint") {
    return null;
  }
  try {
    if ((payload & TAG_MASK) === TAG_OBJ) {
      return decodeTaggedString(instance, payload);
    }
  } catch (_) {}
  try {
    return decodeSelfhostPackedString(instance, payload);
  } catch (_) {}
  return null;
}

function decodeRawStringPtr(instance, ptr) {
  if (typeof ptr !== "number") {
    throw new Error(`expected raw string ptr number, got ${typeof ptr}`);
  }
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for raw string decode");
  }
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const ty = readU32LE(mem, ptr);
  if (ty !== OBJ_STRING) {
    throw new Error(`unexpected raw string object type: ${ty}`);
  }
  const len = readU32LE(mem, ptr + 4);
  const start = ptr + 8;
  const end = start + len;
  if (ptr < 0 || end > mem.length) {
    throw new Error(`raw string range out of bounds: ${ptr}..${end}`);
  }
  return new TextDecoder().decode(mem.subarray(start, end));
}

function decodeStringArg(instance, value) {
  if (typeof value === "bigint") {
    return decodeTaggedString(instance, value);
  }
  if (typeof value === "number") {
    return decodeRawStringPtr(instance, value >>> 0);
  }
  throw new Error(`unsupported string arg type: ${typeof value}`);
}

// Allocate a tagged string in WASM linear memory.
// Requires __heap_ptr global to be exported.
function encodeTaggedString(instance, jsStr) {
  const encoded = new TextEncoder().encode(jsStr);
  const headerSize = 8; // 4 bytes type + 4 bytes length
  const totalSize = headerSize + encoded.length;
  const alignedSize = (totalSize + 7) & ~7; // align to 8 bytes
  const heapPtr = allocHostBuffer(instance, alignedSize, 8);
  const mem = new Uint8Array(instance.exports.memory.buffer);

  // Write string object: [type:i32=1][length:i32][utf8_data...]
  const ptr = heapPtr;
  writeU32LE(mem, ptr, OBJ_STRING);
  writeU32LE(mem, ptr + 4, encoded.length);
  mem.set(encoded, ptr + 8);

  // Return tagged pointer (tag = OBJ = 1)
  return BigInt(ptr) | TAG_OBJ;
}

function encodeSelfhostString(instance, jsStr) {
  const encoded = new TextEncoder().encode(jsStr);
  const alignedSize = (encoded.length + 7) & ~7;
  const heapPtr = allocHostBuffer(instance, alignedSize, 8);
  const mem = new Uint8Array(instance.exports.memory.buffer);

  mem.set(encoded, heapPtr);
  return (BigInt(heapPtr) << 32n) | BigInt(encoded.length);
}

function encodeTaggedBool(value) {
  return value ? 7n : 3n;
}

function encodeTaggedInt(value) {
  return BigInt(value) << 2n;
}

function decodeTaggedInt(value) {
  if (typeof value !== "bigint") {
    throw new Error(`expected tagged int bigint, got ${typeof value}`);
  }
  if ((value & TAG_MASK) !== TAG_INT) {
    throw new Error(`expected tagged int, got tag=${value & TAG_MASK}`);
  }
  return Number(value >> 2n);
}

// Decode a tagged Bytes value from WASM memory into a Uint8Array.
// Supported layouts:
// - legacy Array[Int]-backed bytes: [type=5][length][tagged elems...]
// - raw Bytes: [type=13][length][capacity][data_ptr]
// - BytesView: [type=14][source_ptr][start][end]
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
  if (ty === OBJ_BYTES) {
    const len = readU32LE(mem, ptr + 4);
    const dataPtr = readU32LE(mem, ptr + 12);
    return new Uint8Array(instance.exports.memory.buffer.slice(dataPtr, dataPtr + len));
  }
  if (ty === OBJ_BYTES_VIEW) {
    const sourcePtr = readU32LE(mem, ptr + 4);
    const start = readU32LE(mem, ptr + 8);
    const end = readU32LE(mem, ptr + 12);
    const sourceTagged = BigInt(sourcePtr) | TAG_OBJ;
    return decodeTaggedBytes(instance, sourceTagged).slice(start, end);
  }
  if (ty !== OBJ_ARRAY) {
    throw new Error(
      `expected obj_array(${OBJ_ARRAY})/obj_bytes(${OBJ_BYTES})/obj_bytes_view(${OBJ_BYTES_VIEW}), got ${ty}`,
    );
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

function buildFsMetadataHashParts(filePath) {
  const stat = fs.statSync(filePath, { bigint: true });
  const size = typeof stat.size === "bigint" ? stat.size : BigInt(stat.size);
  const mtimeNs =
    typeof stat.mtimeNs === "bigint"
      ? stat.mtimeNs
      : BigInt(Math.round(Number(stat.mtimeMs) * 1e6));
  const lower = BigInt.asUintN(
    64,
    (size * 0x9e3779b185ebca87n) ^ mtimeNs ^ 0x243f6a8885a308d3n,
  );
  const upper = BigInt.asUintN(
    64,
    ((mtimeNs << 1n) ^ (size << 17n) ^ 0x13198a2e03707344n),
  );
  return { lower, upper };
}

function createPreview2FilesystemHost(projectRoot) {
  const rootPath = path.resolve(projectRoot);
  const descriptors = new Map([[3, { kind: "dir", path: rootPath }]]);
  let nextDescriptor = 4;
  const debugFs = process.env.VIBE_DEBUG_PREVIEW2_FS === "1";
  const debugFsData = process.env.VIBE_DEBUG_PREVIEW2_FS_DATA === "1";
  const debugLogPath = process.env.VIBE_DEBUG_PREVIEW2_FS_LOG || "/tmp/vibe_preview2_fs.log";

  function logDebug(message) {
    if (!debugFs) {
      return;
    }
    fs.appendFileSync(debugLogPath, `${message}\n`);
  }

  function getInstance() {
    if (!instanceRefGlobal) {
      throw new Error("preview2 fs host used before wasm instantiation");
    }
    return instanceRefGlobal;
  }

  function getMem() {
    const instance = getInstance();
    if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
      throw new Error("missing exported memory for Preview2 fs host");
    }
    return new Uint8Array(instance.exports.memory.buffer);
  }

  function writeResultErr(retptr, errCode = 8) {
    const mem = getMem();
    writeU8(mem, retptr, 1);
    writeU32LE(mem, retptr + 4, errCode >>> 0);
  }

  function writeResultOkHandle(retptr, handle) {
    const mem = getMem();
    writeU8(mem, retptr, 0);
    writeU32LE(mem, retptr + 4, handle >>> 0);
  }

  function writeResultOkPtrLen(retptr, ptr, len) {
    const mem = getMem();
    writeU8(mem, retptr, 0);
    writeU32LE(mem, retptr + 4, ptr >>> 0);
    writeU32LE(mem, retptr + 8, len >>> 0);
  }

  function resolveDescriptor(handle) {
    const desc = descriptors.get(handle);
    if (!desc) {
      throw new Error(`unknown filesystem descriptor: ${handle}`);
    }
    return desc;
  }

  function resolvePath(baseHandle, rawPath) {
    const base = resolveDescriptor(baseHandle);
    const candidate = path.resolve(base.path, rawPath);
    if (candidate !== rootPath && !candidate.startsWith(rootPath + path.sep)) {
      throw new Error(`path escapes preopen root: ${rawPath}`);
    }
    return candidate;
  }

  const preview2Preopens = {
    "get-directories"(retptr) {
      // The caller reserves a 16-byte ret area but does not publish heap_ptr
      // before this import. Reusing cabi_realloc/__heap_ptr would alias retptr.
      const listPtr = retptr + 8;
      const mem = getMem();
      writeU32LE(mem, listPtr, 3);
      writeU32LE(mem, retptr, listPtr);
      writeU32LE(mem, retptr + 4, 1);
      logDebug(`[preview2 fs] get-directories retptr=${retptr} listPtr=${listPtr}`);
    },
  };

  const preview2Types = {
    "[method]descriptor.open-at"(baseHandle, _pathFlags, pathPtr, pathLen, openFlags, _flags, retptr) {
      try {
        const rawPath = decodeUtf8Range(getInstance(), pathPtr, pathLen);
        const filePath = resolvePath(baseHandle, rawPath);
        logDebug(`[preview2 fs] open-at base=${baseHandle} path=${JSON.stringify(rawPath)} resolved=${filePath} openFlags=${openFlags}`);
        const wantCreate = (openFlags & 1) !== 0;
        const wantDirectory = (openFlags & 2) !== 0;
        const wantTruncate = (openFlags & 8) !== 0 || (openFlags & 4) !== 0;
        if (wantDirectory) {
          if (!fs.existsSync(filePath) || !fs.statSync(filePath).isDirectory()) {
            writeResultErr(retptr, 24);
            return;
          }
        } else {
          if (wantCreate) {
            fs.mkdirSync(path.dirname(filePath), { recursive: true });
            if (!fs.existsSync(filePath)) {
              fs.writeFileSync(filePath, Buffer.alloc(0));
            }
          }
          if (!fs.existsSync(filePath)) {
            writeResultErr(retptr, 44);
            return;
          }
          if (wantTruncate) {
            fs.writeFileSync(filePath, Buffer.alloc(0));
          }
        }
        const handle = nextDescriptor++;
        descriptors.set(handle, {
          kind: wantDirectory ? "dir" : "file",
          path: filePath,
        });
        writeResultOkHandle(retptr, handle);
      } catch (_err) {
        logDebug(`[preview2 fs] open-at error: ${_err && _err.stack ? _err.stack : _err}`);
        writeResultErr(retptr, 8);
      }
    },
    "[method]descriptor.read"(handle, maxLen, offset, retptr) {
      try {
        const desc = resolveDescriptor(handle);
        logDebug(`[preview2 fs] read handle=${handle} path=${desc.path} maxLen=${maxLen} offset=${offset}`);
        const file = fs.readFileSync(desc.path);
        const start = Number(offset);
        const end = Math.min(file.length, start + Number(maxLen));
        const chunk = file.subarray(start, end);
        const dataPtr = allocPreview2Buffer(getInstance(), chunk.length, 1);
        getMem().set(chunk, dataPtr);
        writeResultOkPtrLen(retptr, dataPtr, chunk.length);
      } catch (_err) {
        logDebug(`[preview2 fs] read error: ${_err && _err.stack ? _err.stack : _err}`);
        writeResultErr(retptr, 8);
      }
    },
    "[method]descriptor.write"(handle, dataPtr, dataLen, offset, retptr) {
      try {
        const desc = resolveDescriptor(handle);
        logDebug(`[preview2 fs] write handle=${handle} path=${desc.path} dataLen=${dataLen} offset=${offset}`);
        const mem = getMem();
        const bytes = Buffer.from(mem.subarray(dataPtr, dataPtr + dataLen));
        if (debugFsData) {
          const preview = Array.from(bytes.subarray(0, Math.min(bytes.length, 16)))
            .map((byte) => byte.toString(16).padStart(2, "0"))
            .join(" ");
          logDebug(`[preview2 fs] write bytes=${preview}`);
        }
        fs.mkdirSync(path.dirname(desc.path), { recursive: true });
        const pos = Number(offset);
        if (pos === 0) {
          fs.writeFileSync(desc.path, bytes);
        } else {
          const fd = fs.openSync(desc.path, "r+");
          try {
            fs.writeSync(fd, bytes, 0, bytes.length, pos);
          } finally {
            fs.closeSync(fd);
          }
        }
        const outMem = getMem();
        writeU8(outMem, retptr, 0);
        writeU32LE(outMem, retptr + 4, dataLen >>> 0);
      } catch (_err) {
        logDebug(`[preview2 fs] write error: ${_err && _err.stack ? _err.stack : _err}`);
        writeResultErr(retptr, 8);
      }
    },
    "[method]descriptor.stat-at"(baseHandle, _pathFlags, pathPtr, pathLen, retptr) {
      try {
        const rawPath = decodeUtf8Range(getInstance(), pathPtr, pathLen);
        const filePath = resolvePath(baseHandle, rawPath);
        const mem = getMem();
        const exists = fs.existsSync(filePath);
        logDebug(`[preview2 fs] stat-at base=${baseHandle} path=${JSON.stringify(rawPath)} resolved=${filePath} exists=${exists}`);
        writeU8(mem, retptr, exists ? 0 : 1);
      } catch (_err) {
        logDebug(`[preview2 fs] stat-at error: ${_err && _err.stack ? _err.stack : _err}`);
        writeResultErr(retptr, 8);
      }
    },
    "[method]descriptor.metadata-hash-at"(baseHandle, _pathFlags, pathPtr, pathLen, retptr) {
      try {
        const rawPath = decodeUtf8Range(getInstance(), pathPtr, pathLen);
        const filePath = resolvePath(baseHandle, rawPath);
        const mem = getMem();
        const exists = fs.existsSync(filePath);
        logDebug(`[preview2 fs] metadata-hash-at base=${baseHandle} path=${JSON.stringify(rawPath)} resolved=${filePath} exists=${exists}`);
        if (!exists) {
          writeResultErr(retptr, 44);
          return;
        }
        const { lower, upper } = buildFsMetadataHashParts(filePath);
        writeU8(mem, retptr, 0);
        writeU64LE(mem, retptr + 8, lower);
        writeU64LE(mem, retptr + 16, upper);
      } catch (_err) {
        logDebug(`[preview2 fs] metadata-hash-at error: ${_err && _err.stack ? _err.stack : _err}`);
        writeResultErr(retptr, 8);
      }
    },
    "[resource-drop]descriptor"(handle) {
      if (handle !== 3) {
        descriptors.delete(handle);
      }
    },
  };

  return {
    "wasi:filesystem/preopens@0.2.6": preview2Preopens,
    "wasi:filesystem/preopens@0.3.0": {
      ...preview2Preopens,
    },
    "wasi:filesystem/types@0.2.6": preview2Types,
    "wasi:filesystem/types@0.3.0": {
      ...preview2Types,
    },
  };
}

function createPreview2CliStreamsHost() {
  const STDOUT_STREAM_HANDLE = 1;
  const STDERR_STREAM_HANDLE = 2;
  const STDIN_STREAM_HANDLE = 3;

  function writeEmptyResultOk(retptr) {
    const mem = new Uint8Array(instanceRefGlobal.exports.memory.buffer);
    writeU8(mem, retptr, 0);
  }

  function resolveWritableStream(handle) {
    if (handle === STDOUT_STREAM_HANDLE) {
      return process.stdout;
    }
    if (handle === STDERR_STREAM_HANDLE) {
      return process.stderr;
    }
    throw new Error(`unknown output-stream handle: ${handle}`);
  }

  const cliStdout = {
    "get-stdout"() {
      return STDOUT_STREAM_HANDLE;
    },
  };

  const cliStderr = {
    "get-stderr"() {
      return STDERR_STREAM_HANDLE;
    },
  };

  const cliStdin = {
    "get-stdin"() {
      return STDIN_STREAM_HANDLE;
    },
  };

  const ioStreams = new Proxy(
    {
      "[method]output-stream.blocking-write-and-flush"(handle, dataPtr, dataLen, retptr) {
        const instance = instanceRefGlobal;
        if (!(instance?.exports?.memory instanceof WebAssembly.Memory)) {
          throw new Error("missing exported memory for output-stream write");
        }
        const mem = new Uint8Array(instance.exports.memory.buffer);
        const bytes = mem.subarray(dataPtr, dataPtr + dataLen);
        resolveWritableStream(handle).write(Buffer.from(bytes));
        writeEmptyResultOk(retptr);
      },
      "[method]input-stream.blocking-read"(_handle, _maxLen, retptr) {
        // Tests run without an interactive stdin; signal EOF (empty list) so
        // callers like `Stdin::read_char` see `-1` and `read_line` returns "".
        const instance = instanceRefGlobal;
        if (!(instance?.exports?.memory instanceof WebAssembly.Memory)) {
          throw new Error("missing exported memory for input-stream read");
        }
        const mem = new Uint8Array(instance.exports.memory.buffer);
        // result<list<u8>, stream-error>: tag=0 (ok), then list { ptr=0, len=0 }
        writeU8(mem, retptr, 0);
        writeU32LE(mem, retptr + 4, 0); // ptr
        writeU32LE(mem, retptr + 8, 0); // len
      },
      "[resource-drop]output-stream"(_handle) {},
      "[resource-drop]input-stream"(_handle) {},
    },
    {
      get(target, key) {
        if (key in target) {
          return target[key];
        }
        return () => 0;
      },
    },
  );

  return {
    "wasi:cli/stdout@0.2.0": cliStdout,
    "wasi:cli/stderr@0.2.0": cliStderr,
    "wasi:cli/stdin@0.2.0": cliStdin,
    "wasi:io/streams@0.2.0": ioStreams,
  };
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
  const {
    invokes,
    wasmPath,
    passthroughArgs,
    benchCount,
    benchWarmup,
    benchSetup,
  } = parseArgs(process.argv.slice(2));
  if (passthroughArgs.length > 0) {
    if (process.env.VIBE_INPUT === undefined && passthroughArgs.length >= 1) {
      process.env.VIBE_INPUT = passthroughArgs[0];
    }
    if (process.env.VIBE_OUTPUT === undefined && passthroughArgs.length >= 2) {
      process.env.VIBE_OUTPUT = passthroughArgs[1];
    }
    if (process.env.VIBE_ENTRY === undefined && passthroughArgs.length >= 3) {
      process.env.VIBE_ENTRY = passthroughArgs[2];
    }
  }
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

  function decodeJsonHostValue(jsonTagged) {
    return JSON.parse(decodeStringArg(instanceRef, jsonTagged));
  }

  function encodeJsonHostValue(value) {
    return encodeTaggedString(instanceRef, JSON.stringify(value));
  }

  const vibeModule = new Proxy(
    {
      sh(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        cp.execSync(cmd, { stdio: "inherit", shell: "/bin/bash" });
        return 0n;
      },
      sh_lines(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        try {
          const output = cp.execSync(cmd, { encoding: "utf-8", shell: "/bin/bash", stdio: ["pipe", "pipe", "pipe"] });
          return encodeTaggedString(instanceRef, output.trimEnd());
        } catch (e) {
          const stderr = e.stderr ? e.stderr.toString().trim() : e.message;
          return encodeTaggedString(instanceRef, "error: " + stderr);
        }
      },
      path(pathValue) {
        const input = decodeStringArg(instanceRef, pathValue);
        return encodeTaggedString(instanceRef, input);
      },
      ["resolve-path"](pathTagged) {
        const input = decodeStringArg(instanceRef, pathTagged);
        return encodeTaggedString(instanceRef, input);
      },
      resolve_path(pathTagged) {
        return this["resolve-path"](pathTagged);
      },
      fs_read_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          const content = fs.readFileSync(filePath, "utf8");
          return encodeTaggedString(instanceRef, content);
        } catch (e) {
          throw new Error(`fs_read_file failed for '${filePath}': ${e.message}`);
        }
      },
      fs_exists(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        return encodeTaggedBool(fs.existsSync(filePath));
      },
      fs_stat_token(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const { lower, upper } = buildFsMetadataHashParts(filePath);
        return encodeTaggedInt(BigInt.asUintN(61, lower ^ upper));
      },
      fs_write_file(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(filePath, content, "utf8");
        return 0n;
      },
      fs_write_bytes(pathTagged, bytesTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const bytes = decodeTaggedBytes(instanceRef, bytesTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        fs.writeFileSync(filePath, bytes);
        return 0n;
      },
      fs_readdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          const entries = fs.readdirSync(dirPath);
          // Return as newline-separated string with type info
          const lines = entries.map((name) => {
            const fullPath = path.join(dirPath, name);
            try {
              const stat = fs.statSync(fullPath);
              return (stat.isDirectory() ? "d " : "- ") + name;
            } catch {
              return "? " + name;
            }
          });
          return encodeTaggedString(instanceRef, lines.join("\n"));
        } catch (e) {
          return encodeTaggedString(instanceRef, "");
        }
      },
      fs_getcwd() {
        return encodeTaggedString(instanceRef, process.cwd());
      },
      fs_chdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          process.chdir(dirPath);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_is_dir(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          return encodeTaggedBool(fs.statSync(filePath).isDirectory());
        } catch (e) {
          return encodeTaggedBool(false);
        }
      },
      fs_is_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          return encodeTaggedBool(fs.statSync(filePath).isFile());
        } catch (e) {
          return encodeTaggedBool(false);
        }
      },
      fs_mkdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.mkdirSync(dirPath);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_mkdir_p(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.mkdirSync(dirPath, { recursive: true });
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_remove(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.rmSync(filePath, { recursive: true, force: true });
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_rename(srcTagged, dstTagged) {
        const src = decodeStringArg(instanceRef, srcTagged);
        const dst = decodeStringArg(instanceRef, dstTagged);
        try {
          fs.renameSync(src, dst);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_copy(srcTagged, dstTagged) {
        const src = decodeStringArg(instanceRef, srcTagged);
        const dst = decodeStringArg(instanceRef, dstTagged);
        try {
          fs.copyFileSync(src, dst);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_append(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        try {
          fs.appendFileSync(filePath, content, "utf8");
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_open_write(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const fd = fs.openSync(filePath, "w");
        return encodeTaggedInt(fd);
      },
      fs_write_chunk(fdTagged, strTagged) {
        const fd = decodeTaggedInt(fdTagged);
        const str = decodeStringArg(instanceRef, strTagged);
        fs.writeSync(fd, str);
        return 0n;
      },
      fs_close_write(fdTagged) {
        const fd = decodeTaggedInt(fdTagged);
        fs.closeSync(fd);
        return 0n;
      },
      json_parse(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        // Parse and re-stringify to validate JSON, then return as tagged string.
        // The vibe runtime treats Json values as opaque tagged strings at the
        // host boundary; higher-level Json::get etc. operate on the parsed tree
        // inside the vibe interpreter/compiled code.
        try {
          const parsed = JSON.parse(str);
          return encodeTaggedString(instanceRef, JSON.stringify(parsed));
        } catch (e) {
          return encodeTaggedString(instanceRef, "null");
        }
      },
      json_stringify(valueTagged) {
        // The value is already a tagged string containing JSON text.
        // Just pass it through (identity for string-encoded Json values).
        return valueTagged;
      },
      json_get(valueTagged, keyTagged) {
        const value = decodeJsonHostValue(valueTagged);
        const key = decodeStringArg(instanceRef, keyTagged);
        if (value === null || Array.isArray(value) || typeof value !== "object") {
          throw new Error("Json::get: not an object");
        }
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          throw new Error(`Json::get: missing key '${key}'`);
        }
        return encodeJsonHostValue(value[key]);
      },
      json_string(valueTagged) {
        const value = decodeJsonHostValue(valueTagged);
        if (typeof value !== "string") {
          throw new Error("Json::string: not a string");
        }
        return encodeTaggedString(instanceRef, value);
      },
      ["env-get"](nameTagged) {
        const name = decodeStringArg(instanceRef, nameTagged);
        const val = process.env[name] || "";
        return encodeTaggedString(instanceRef, val);
      },
      ["args-len"]() {
        return encodeTaggedInt(passthroughArgs.length);
      },
      ["args-get"](indexTagged) {
        const index = decodeTaggedInt(indexTagged);
        const val =
          index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
        return encodeTaggedString(instanceRef, val);
      },
      env_get(nameTagged) {
        return this["env-get"](nameTagged);
      },
      args_len() {
        return this["args-len"]();
      },
      args_get(indexTagged) {
        return this["args-get"](indexTagged);
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

  const preview2FsHost = createPreview2FilesystemHost(
    process.env.VIBE_PREOPEN_DIR || process.cwd(),
  );
  const preview2CliStreamsHost = createPreview2CliStreamsHost();

  // Selfhost-compiled WASM uses "Env" and "Fs" module names for effect imports
  const envModule = {
    ArgsLen() {
      return encodeTaggedInt(passthroughArgs.length);
    },
    ArgsGet(indexTagged) {
      const index = decodeTaggedInt(indexTagged);
      const val =
        index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
      return encodeTaggedString(instanceRef, val);
    },
    Get(nameTagged) {
      const name = decodeStringArg(instanceRef, nameTagged);
      const val = process.env[name] ?? "";
      return encodeTaggedString(instanceRef, val);
    },
  };
  const fsModule = {
    ReadFile(pathTagged) {
      return vibeModule.fs_read_file(pathTagged);
    },
    WriteFile(pathTagged, contentTagged) {
      return vibeModule.fs_write_file(pathTagged, contentTagged);
    },
    WriteBytes(pathTagged, bytesTagged) {
      return vibeModule.fs_write_bytes(pathTagged, bytesTagged);
    },
    Exists(pathTagged) {
      return vibeModule.fs_exists(pathTagged);
    },
    StatToken(pathTagged) {
      return vibeModule.fs_stat_token(pathTagged);
    },
    ReadDir(pathTagged) {
      return vibeModule.fs_readdir(pathTagged);
    },
    IsDir(pathTagged) {
      return vibeModule.fs_is_dir(pathTagged);
    },
    IsFile(pathTagged) {
      return vibeModule.fs_is_file(pathTagged);
    },
    Mkdir(pathTagged) {
      return vibeModule.fs_mkdir(pathTagged);
    },
    MkdirP(pathTagged) {
      return vibeModule.fs_mkdir_p(pathTagged);
    },
    Remove(pathTagged) {
      return vibeModule.fs_remove(pathTagged);
    },
    Rename(srcTagged, dstTagged) {
      return vibeModule.fs_rename(srcTagged, dstTagged);
    },
    Copy(srcTagged, dstTagged) {
      return vibeModule.fs_copy(srcTagged, dstTagged);
    },
    Append(pathTagged, contentTagged) {
      return vibeModule.fs_append(pathTagged, contentTagged);
    },
    Getcwd() {
      return vibeModule.fs_getcwd();
    },
    Chdir(pathTagged) {
      return vibeModule.fs_chdir(pathTagged);
    },
    OpenWrite(pathTagged) {
      return vibeModule.fs_open_write(pathTagged);
    },
    WriteChunk(fdTagged, strTagged) {
      return vibeModule.fs_write_chunk(fdTagged, strTagged);
    },
    CloseWrite(fdTagged) {
      return vibeModule.fs_close_write(fdTagged);
    },
  };
  // Stdin/Stdout effect imports for vibe/io and vibe/prelude/io helpers.
  const stdinModule = {
    ReadStream(_maxBytesTagged) {
      // tests run without a controlling TTY; return empty string.
      return encodeTaggedString(instanceRef, "");
    },
    ReadChar() {
      // -1 indicates EOF.
      return encodeTaggedInt(-1);
    },
  };
  const stdoutModule = {
    WriteStream(strTagged) {
      const str = decodeStringArg(instanceRef, strTagged);
      process.stdout.write(str);
      return 0n;
    },
    WriteChar(codeTagged) {
      const code = decodeTaggedInt(codeTagged);
      process.stdout.write(String.fromCharCode(code));
      return 0n;
    },
  };

  const imports = new Proxy(
    {
      vibe: vibeModule,
      Env: envModule,
      Fs: fsModule,
      Stdin: stdinModule,
      Stdout: stdoutModule,
      wasi_snapshot_preview1: wasiModule,
      "wasi:cli/stdout@0.2.0": preview2CliStreamsHost["wasi:cli/stdout@0.2.0"],
      "wasi:cli/stderr@0.2.0": preview2CliStreamsHost["wasi:cli/stderr@0.2.0"],
      "wasi:cli/stdin@0.2.0": preview2CliStreamsHost["wasi:cli/stdin@0.2.0"],
      "wasi:io/streams@0.2.0": preview2CliStreamsHost["wasi:io/streams@0.2.0"],
      "wasi:filesystem/preopens@0.2.6":
        preview2FsHost["wasi:filesystem/preopens@0.2.6"],
      "wasi:filesystem/types@0.2.6":
        preview2FsHost["wasi:filesystem/types@0.2.6"],
      "wasi:filesystem/preopens@0.3.0":
        preview2FsHost["wasi:filesystem/preopens@0.3.0"],
      "wasi:filesystem/types@0.3.0":
        preview2FsHost["wasi:filesystem/types@0.3.0"],
    },
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
  hostAllocPtrGlobal = null;
  let didInitStart = false;
  let initHeapBeforeStart = 0;
  const resolvedEnvCache = new Map();
  const invokeExport = (invoke) => {
    const fn = instance.exports[invoke];
    if (typeof fn !== "function") {
      throw new Error(`missing export: ${invoke}`);
    }
    const prefersZeroEnvFirst =
      invoke.startsWith("probe_") ||
      invoke.startsWith("selfbuild_") ||
      process.env.VIBE_PREFER_ZERO_ENV_FIRST === "1";
    const skipRunInit = process.env.VIBE_SKIP_RUN_INIT === "1";
    let resolvedEnv = 0;
    if (!skipRunInit && invoke !== "_start" && typeof instance.exports._start === "function") {
      if (!didInitStart) {
        initHeapBeforeStart =
          instance.exports.__heap_ptr instanceof WebAssembly.Global
            ? instance.exports.__heap_ptr.value
            : 0;
        instance.exports._start();
        didInitStart = true;
        const fsRootDescriptor = instance.exports.__fs_root_descriptor;
        if (fsRootDescriptor instanceof WebAssembly.Global) {
          fsRootDescriptor.value = -1;
        }
      }
      if (resolvedEnvCache.has(invoke)) {
        resolvedEnv = resolvedEnvCache.get(invoke);
      } else {
        const funcIdx = exportFuncIndices[invoke];
        const tableSlot = funcIdx !== undefined ? funcToTableSlot[funcIdx] : undefined;
        resolvedEnv =
          tableSlot !== undefined ? findClosureEnv(instance, initHeapBeforeStart, tableSlot) : 0;
        resolvedEnvCache.set(invoke, resolvedEnv);
      }
    }
    let result;
    let isSelfhost = false;
    const invokeWithEnv = (envValue) => {
      if (invoke === "_start") {
        return { result: fn(), isSelfhost: false };
      }
      try {
        return { result: fn(envValue), isSelfhost: false };
      } catch (typeErr) {
        if (typeErr instanceof TypeError) {
          return { result: fn(BigInt(envValue)), isSelfhost: true };
        }
        throw typeErr;
      }
    };
    try {
      const envCandidates =
        invoke === "_start"
          ? [0]
          : resolvedEnv !== 0
            ? (prefersZeroEnvFirst ? [0, resolvedEnv] : [resolvedEnv, 0])
            : [0];
      let lastErr = null;
      for (const envValue of envCandidates) {
        try {
          ({ result, isSelfhost } = invokeWithEnv(envValue));
          lastErr = null;
          break;
        } catch (err) {
          lastErr = err;
        }
      }
      if (lastErr !== null) {
        throw lastErr;
      }
      if (invoke === "_start") {
        didInitStart = true;
      }
      return { result, isSelfhost };
    } catch (err) {
      const heapGlobal = instance.exports.__heap_ptr;
      const mem = new Uint8Array(instance.exports.memory.buffer);
      const hpRaw = heapGlobal?.value;
      const hp = typeof hpRaw === "bigint" ? Number(hpRaw) : hpRaw;
      const hpHex =
        typeof hpRaw === "bigint"
          ? hpRaw.toString(16)
          : hpRaw !== undefined && hpRaw !== null
            ? hpRaw.toString(16)
            : "n/a";
      console.error(`[crash debug] heap_ptr=${hpRaw} (0x${hpHex}), memory_size=${mem.length} (${(mem.length / 65536)} pages) / ${err?.message || err}`);
      console.error(`[crash debug] mem[0..32]: ${Array.from(mem.slice(0, 32)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
      if (typeof hp === "number" && hp >= 8 && hp < mem.length - 32) {
        console.error(`[crash debug] mem[heap-8..heap+24]: ${Array.from(mem.slice(hp - 8, hp + 24)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
      }
      throw err;
    }
  };
  if (benchCount !== null) {
    if (invokes.length !== 1) {
      throw new Error("bench mode requires exactly one --invoke target");
    }
    if (benchSetup !== null) {
      invokeExport(benchSetup);
    }
    for (let i = 0; i < benchWarmup; i += 1) {
      invokeExport(invokes[0]);
    }
    const startNs = process.hrtime.bigint();
    for (let i = 0; i < benchCount; i += 1) {
      invokeExport(invokes[0]);
    }
    const elapsedUs = Number(process.hrtime.bigint() - startNs) / 1000;
    console.log(String(elapsedUs));
    return;
  }
  let result;
  let isSelfhost = false;
  for (const invoke of invokes) {
    ({ result, isSelfhost } = invokeExport(invoke));
  }
  const invoke = invokes[invokes.length - 1];
  if (typeof result === "bigint") {
    // Check if the result is a tagged object (could be Bytes from selfbuild)
    if (
      (result & TAG_MASK) === TAG_OBJ &&
      (invoke === "selfbuild_compile_stage2" ||
        invoke === "selfbuild_compile_cli_adapter")
    ) {
      // Decode result as Bytes and write to expected output path
      const bytes = decodeTaggedBytes(instanceRef, result);
      const outPath =
        invoke === "selfbuild_compile_cli_adapter"
          ? "_build/bench/selfhost_cli_adapter/selfhost_cli_stage1.wasm"
          : "_build/bench/selfhost_wasi_selfbuild/index_stage2.wasm";
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
      // For string/array/record results, output display text on first line
      // then raw tagged i64 on second line. CLI checks for VIBE_DISPLAY: prefix.
      const tag = Number(result & 3n);
      if (tag === 1) {
        // Object pointer — try to render display text
        const ptr = Number(result & ~3n);
        const mem = instance.exports.memory;
        if (mem && ptr > 0 && ptr + 8 <= mem.buffer.byteLength) {
          const view = new DataView(mem.buffer);
          const ty = view.getUint32(ptr, true);
          if (ty === 1) {
            // String object
            const len = view.getUint32(ptr + 4, true);
            if (ptr + 8 + len <= mem.buffer.byteLength) {
              const bytes = new Uint8Array(mem.buffer, ptr + 8, len);
              const text = new TextDecoder().decode(bytes);
              console.log("VIBE_DISPLAY:" + JSON.stringify(text));
            }
          } else if (ty === 5) {
            // Array — show element count
            const len = view.getUint32(ptr + 4, true);
            console.log("VIBE_DISPLAY:[Array(" + len + ")]");
          }
        }
      }
      // Always output raw tagged i64 as last line
      console.log(result.toString());
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
        const msg = tryDecodeExceptionString(instanceRefGlobal, payload);
        if (msg !== null) {
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
              const msg = tryDecodeExceptionString(instanceRefGlobal, payload);
              if (msg !== null) {
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
