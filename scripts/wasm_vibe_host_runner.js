#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { Worker, MessageChannel, receiveMessageOnPort } = require("node:worker_threads");

// Guest Fs::write_file / Fs::write_bytes land here. Write via a same-dir temp
// file + rename so a concurrent READER never sees a truncated file -- the
// persistent caches under _build/vibe_* are content-keyed and shared, and the
// parallel unit-test runner (VIBE_UNIT_TEST_JOBS > 1) has many compilers
// reading and writing the same hot keys; plain writeFileSync opens with
// O_TRUNC and exposes a partial-file window that torn a cache row into an
// "invalid persistent ... cache row" flake. rename(2) is atomic on POSIX and
// same-content racers simply last-write-win as complete files.
function atomicWriteFileSync(filePath, data, encoding) {
  const tmp =
    filePath + ".tmp-" + process.pid + "-" + Math.random().toString(36).slice(2, 8);
  try {
    fs.writeFileSync(tmp, data, encoding);
    fs.renameSync(tmp, filePath);
  } catch (e) {
    try {
      fs.rmSync(tmp, { force: true });
    } catch (_) {}
    throw e;
  }
}

// Publish UTF-8 text without ever replacing an existing path. A same-directory
// O_EXCL temp plus hard link gives no-replace atomic publication on filesystems
// that support links. Existing regular files are accepted only when their raw
// bytes exactly match; every I/O, unsupported, symlink, or nonregular case
// fails closed. This is intentionally separate from atomicWriteFileSync:
// immutable cache publication must never have last-writer-wins semantics.
function publishImmutableTextSync(filePath, content) {
  const data = Buffer.from(content, "utf8");
  const tmp =
    filePath + ".immutable-tmp-" + process.pid + "-" + Math.random().toString(36).slice(2, 12);
  try {
    fs.writeFileSync(tmp, data, { flag: "wx" });
    try {
      fs.linkSync(tmp, filePath);
      return true;
    } catch (e) {
      if (e.code !== "EEXIST") return false;
      try {
        if (!fs.lstatSync(filePath).isFile()) return false;
        return Buffer.compare(fs.readFileSync(filePath), data) === 0;
      } catch (_) {
        return false;
      }
    }
  } catch (_) {
    return false;
  } finally {
    try {
      fs.rmSync(tmp, { force: true });
    } catch (_) {}
  }
}
const readline = require("node:readline");

// Backs the tcp_connect/tcp_read/tcp_write/tcp_close and
// http_request/response_status/response_header/response_body/close host
// imports below: Node has no synchronous TCP or HTTP client, so the real
// async work (net.Socket / http.request) runs on a worker thread while this
// thread blocks on Atomics.wait() until the worker signals completion, then
// drains the worker's response with receiveMessageOnPort() -- the standard
// Node pattern for making an inherently-async operation look synchronous to
// a caller (here, a wasm guest's synchronous host-import call) that cannot
// itself await. Each bridge starts its worker lazily on first use so a
// program that never touches a socket or HTTP never pays for the extra
// thread.
function makeWorkerBridge(workerScript) {
  let workerPort = null;
  return function call(op, extra) {
    if (!workerPort) {
      const { port1, port2 } = new MessageChannel();
      const worker = new Worker(path.join(__dirname, workerScript), {
        workerData: { port: port2 },
        transferList: [port2],
      });
      worker.unref();
      workerPort = port1;
    }
    const signal = new Int32Array(new SharedArrayBuffer(4));
    workerPort.postMessage(Object.assign({ id: 0, signal, op }, extra));
    Atomics.wait(signal, 0, 0);
    const { message } = receiveMessageOnPort(workerPort);
    if (message.error) {
      throw new Error(message.error);
    }
    return message.result;
  };
}
const tcpWorkerCall = makeWorkerBridge("wasm_vibe_host_runner_tcp_worker.js");
const httpWorkerCall = makeWorkerBridge("wasm_vibe_host_runner_http_worker.js");

const TAG_MASK = 3n;
const TAG_INT = 0n;
const TAG_OBJ = 1n;

const OBJ_STRING = 1;
const OBJ_ARRAY = 5;
const OBJ_BYTES = 13;
const OBJ_BYTES_VIEW = 14;
const REQUESTED_HOST_IMPORT_ABI = process.env.VIBE_IMPORT_ABI || "";
let HOST_IMPORT_ABI = REQUESTED_HOST_IMPORT_ABI || "tagged";
const PROFILE_START_NS = process.hrtime.bigint();

function isPersistentArtifactCacheDisabled(filePath) {
  return (
    process.env.VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE === "1" &&
    filePath.includes("_build/vibe_selfhost_artifact_")
  );
}

function toU32(value) {
  return Number(value) >>> 0;
}

function usage() {
  console.error(
    "usage: node scripts/wasm_vibe_host_runner.js [--daemon] [--invoke <name>]... [--invoke-batch-dir <dir>] [--bench-count <n> --bench-warmup <n> --bench-setup <name>] <module.wasm> [argv...]",
  );
}

function parseArgs(argv) {
  const invokes = [];
  let wasmPath = null;
  const passthroughArgs = [];
  let benchCount = null;
  let benchWarmup = 0;
  let benchSetup = null;
  let daemon = false;
  let invokeBatchDir = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--daemon") {
      daemon = true;
      continue;
    }
    if (arg === "--invoke-batch-dir") {
      if (i + 1 >= argv.length) {
        throw new Error("--invoke-batch-dir requires a directory");
      }
      invokeBatchDir = argv[i + 1];
      i += 1;
      continue;
    }
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
    if (wasmPath !== null) {
      passthroughArgs.push(arg);
      continue;
    }
    if (arg.startsWith("-")) {
      throw new Error(`unknown option: ${arg}`);
    }
    wasmPath = arg;
  }
  if (wasmPath === null) {
    throw new Error("missing wasm path");
  }
  if (invokes.length === 0) {
    invokes.push("_start");
  }
  return { daemon, invokes, wasmPath, passthroughArgs, benchCount, benchWarmup, benchSetup, invokeBatchDir };
}

function parsePositiveIntEnv(name) {
  const raw = process.env[name] || "";
  if (raw === "") {
    return 0;
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

function parseNonNegativeIntEnv(name, fallback) {
  const raw = process.env[name] || "";
  if (raw === "") {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return value;
}

function rawHostAllocMode() {
  const mode = process.env.VIBE_WASM_HOST_ALLOC_MODE || "heap-bump";
  if (mode === "heap-bump" || mode === "arena") {
    return mode;
  }
  throw new Error("VIBE_WASM_HOST_ALLOC_MODE must be 'heap-bump' or 'arena'");
}

function preGrowWasmMemory(instance) {
  if (HOST_IMPORT_ABI !== "raw") {
    return;
  }
  const targetPages = parsePositiveIntEnv("VIBE_WASM_PRE_GROW_PAGES");
  if (targetPages <= 0) {
    return;
  }
  const memory = instance.exports.memory;
  if (!(memory instanceof WebAssembly.Memory)) {
    return;
  }
  const currentPages = memory.buffer.byteLength / 65536;
  if (targetPages <= currentPages) {
    return;
  }
  memory.grow(targetPages - currentPages);
  if (process.env.VIBE_DEBUG_IMPORTS === "1") {
    console.error(`[wasm-memory] pre-grow pages=${currentPages}->${targetPages}`);
  }
}

function readU32LE(mem, pos) {
  pos = toU32(pos);
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
  pos = toU32(pos);
  mem[pos] = val & 0xff;
  mem[pos + 1] = (val >>> 8) & 0xff;
  mem[pos + 2] = (val >>> 16) & 0xff;
  mem[pos + 3] = (val >>> 24) & 0xff;
}

function writeU64LE(mem, pos, val) {
  pos = toU32(pos);
  let next = BigInt.asUintN(64, BigInt(val));
  for (let i = 0; i < 8; i += 1) {
    mem[pos + i] = Number(next & 0xffn);
    next >>= 8n;
  }
}

function writeU8(mem, pos, val) {
  pos = toU32(pos);
  mem[pos] = val & 0xff;
}

function decodeUtf8Range(instance, ptr, len) {
  ptr = toU32(ptr);
  len = toU32(len);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  if (ptr < 0 || len < 0 || ptr + len > mem.length) {
    throw new Error(`utf8 range out of bounds: ${ptr}..${ptr + len}`);
  }
  return new TextDecoder().decode(mem.subarray(ptr, ptr + len));
}

function ensureMemoryCapacity(instance, end) {
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory");
  }
  const memory = instance.exports.memory;
  if (end <= memory.buffer.byteLength) {
    return;
  }
  const pagesNeeded = Math.ceil((end - memory.buffer.byteLength) / 65536);
  memory.grow(pagesNeeded);
}

function allocPreview2Buffer(instance, size, align = 4) {
  if (typeof instance.exports.cabi_realloc === "function") {
    // cabi_realloc returns a pointer that may be an i64 (BigInt) on the linear
    // backend; normalize before the i32 coercion (`>>> 0` throws on BigInt).
    const rawPtr = instance.exports.cabi_realloc(0, 0, align, size);
    const ptr = (typeof rawPtr === "bigint" ? Number(rawPtr) : rawPtr) >>> 0;
    ensureMemoryCapacity(instance, ptr + size);
    return ptr;
  }
  const heapGlobal = instance.exports.__heap_ptr;
  if (!heapGlobal) {
    throw new Error("missing cabi_realloc/__heap_ptr for Preview2 allocation");
  }
  let mem = new Uint8Array(instance.exports.memory.buffer);
  const heapPtr = toU32(heapGlobal.value);
  const alignedPtr = ((heapPtr + (align - 1)) & ~(align - 1)) >>> 0;
  const heapAlign = Math.max(align, 4);
  const next = ((alignedPtr + size + (heapAlign - 1)) & ~(heapAlign - 1)) >>> 0;
  if (next > mem.length) {
    const pagesNeeded = Math.ceil((next - mem.length) / 65536);
    instance.exports.memory.grow(pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }
  heapGlobal.value = next;
  return alignedPtr;
}

let hostAllocPtrGlobal = null;

function setHeapGlobalValue(heapGlobal, value) {
  if (typeof heapGlobal.value === "bigint") {
    heapGlobal.value = BigInt(value);
  } else {
    heapGlobal.value = value >>> 0;
  }
}

function allocGuestHeapHostBuffer(instance, size, align) {
  const heapGlobal = instance.exports.__heap_ptr;
  if (!(heapGlobal instanceof WebAssembly.Global)) {
    throw new Error("missing __heap_ptr for raw host heap allocation");
  }
  let mem = new Uint8Array(instance.exports.memory.buffer);
  const heapPtr = toU32(heapGlobal.value);
  const alignedPtr = ((heapPtr + (align - 1)) & ~(align - 1)) >>> 0;
  const heapAlign = Math.max(align, 4);
  const next = ((alignedPtr + size + (heapAlign - 1)) & ~(heapAlign - 1)) >>> 0;
  if (next > mem.length) {
    const pagesNeeded = Math.ceil((next - mem.length) / 65536);
    instance.exports.memory.grow(pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }
  setHeapGlobalValue(heapGlobal, next);
  hostAllocPtrGlobal = hostAllocPtrGlobal === null ? next : Math.max(hostAllocPtrGlobal, next);
  return alignedPtr;
}

function allocHostBuffer(instance, size, align = 8) {
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for host allocation");
  }
  if (HOST_IMPORT_ABI === "raw" && rawHostAllocMode() === "heap-bump") {
    if (instance.exports.__heap_ptr instanceof WebAssembly.Global) {
      return allocGuestHeapHostBuffer(instance, size, align);
    }
    if (process.env.VIBE_WASM_HOST_ALLOC_MODE === "heap-bump") {
      throw new Error("missing __heap_ptr for explicit raw heap-bump host allocation");
    }
    // Hand-written raw ABI probes may not export __heap_ptr. Keep those on the
    // arena path while generated selfhost artifacts use heap-bump by default.
  }
  let mem = new Uint8Array(instance.exports.memory.buffer);
  if (hostAllocPtrGlobal === null) {
    if (HOST_IMPORT_ABI === "raw" && instance.exports.__heap_ptr instanceof WebAssembly.Global) {
      const heapPtr = toU32(instance.exports.__heap_ptr.value);
      const guardBytes = parseNonNegativeIntEnv(
        "VIBE_WASM_HOST_ARENA_GUARD_BYTES",
        128 * 1024 * 1024,
      );
      hostAllocPtrGlobal = heapPtr + guardBytes;
    } else {
      hostAllocPtrGlobal = mem.length;
    }
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

function decodeSelfhostPackedBytes(instance, packed) {
  if (typeof packed !== "bigint") {
    throw new Error(`expected selfhost packed bytes bigint, got ${typeof packed}`);
  }
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("missing exported memory for selfhost bytes decode");
  }
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const ptr = Number(packed >> 32n);
  const len = Number(packed & 0xffffffffn);
  const end = ptr + len;
  if (ptr < 0 || len < 0 || end < ptr || end > mem.length) {
    throw new Error(`selfhost bytes range out of bounds: ${ptr}..${end}`);
  }
  return new Uint8Array(instance.exports.memory.buffer.slice(ptr, end));
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
    if (hostUsesRawAbi()) {
      return decodeSelfhostPackedString(instance, value);
    }
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

// Allocate an Array[String] in WASM linear memory matching codegen layout:
//   base+0  capacity (i32)
//   base+4  type tag (i32 = OBJ_ARRAY = 5)
//   base+8  length (i32)
//   base+12 elements (each i32 = tagged String pointer)
// Returned tagged i64 = (base+4) | TAG_OBJ.
function encodeTaggedStringArray(instance, jsStrings) {
  const stringPtrs = jsStrings.map((s) => {
    const tagged = encodeTaggedString(instance, s);
    // Element slots are 4 bytes; tagged String fits in 32 bits since the
    // pointer is below 4GiB.
    return Number(tagged & 0xffffffffn);
  });
  const len = stringPtrs.length;
  const totalSize = 4 + 8 + len * 4; // cap + header + elements
  const alignedSize = (totalSize + 7) & ~7;
  const base = allocHostBuffer(instance, alignedSize, 8);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  writeU32LE(mem, base, len); // capacity = len
  writeU32LE(mem, base + 4, OBJ_ARRAY);
  writeU32LE(mem, base + 8, len);
  for (let i = 0; i < len; i += 1) {
    writeU32LE(mem, base + 12 + i * 4, stringPtrs[i]);
  }
  return BigInt(base + 4) | TAG_OBJ;
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

function decodeTaggedOrRawInt(value) {
  if (typeof value !== "bigint") {
    throw new Error(`expected int bigint, got ${typeof value}`);
  }
  if ((value & TAG_MASK) === TAG_INT) {
    return Number(value >> 2n);
  }
  return Number(value);
}

function hostUsesRawAbi() {
  return HOST_IMPORT_ABI === "raw";
}

function encodeHostBool(value) {
  return hostUsesRawAbi() ? (value ? 1n : 0n) : encodeTaggedBool(value);
}

function encodeHostInt(value) {
  return hostUsesRawAbi() ? BigInt(value) : encodeTaggedInt(value);
}

function decodeHostInt(value) {
  return hostUsesRawAbi() ? Number(value) : decodeTaggedOrRawInt(value);
}

function encodeHostString(instance, value) {
  return hostUsesRawAbi() ? encodeSelfhostString(instance, value) : encodeTaggedString(instance, value);
}

// Construct a guest Bytes value from a host Uint8Array/Buffer (the inverse of
// decodeHostBytes). Raw ABI (selfhost / #632 Fs::read_bytes): the layout the
// linear backend's gen_bytes_new + bytes_push produce — header
// [+0: -capacity][+4: len][+8: data_ptr] with the bytes inline at +12, returned
// as an UNTAGGED pointer. Untagged means the RC `&1` guard skips it (Bytes are
// not rc-managed in this representation, same as gen_bytes_new), so no refcount
// word is needed. Capacity is stored negated (bytes_push reads `avail = 0 - cap`).
function encodeHostBytesRaw(instance, buf) {
  const len = buf.length;
  const aligned = (12 + len + 7) & ~7;
  const ptr = allocHostBuffer(instance, aligned, 8);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  writeU32LE(mem, ptr, toU32(-len)); // capacity = len, stored negated
  writeU32LE(mem, ptr + 4, len); // length
  writeU32LE(mem, ptr + 8, ptr + 12); // data_ptr -> inline data
  mem.set(buf, ptr + 12);
  return BigInt(ptr);
}

// Tagged ABI: an OBJ_BYTES heap object [type=13][len][cap][data_ptr] with the
// data in a separate buffer, returned with TAG_OBJ (matches decodeTaggedBytes).
function encodeHostBytesTagged(instance, buf) {
  const len = buf.length;
  const dataPtr = allocHostBuffer(instance, Math.max((len + 7) & ~7, 8), 8);
  const hdrPtr = allocHostBuffer(instance, 16, 8);
  const mem = new Uint8Array(instance.exports.memory.buffer);
  mem.set(buf, dataPtr);
  writeU32LE(mem, hdrPtr, OBJ_BYTES);
  writeU32LE(mem, hdrPtr + 4, len);
  writeU32LE(mem, hdrPtr + 8, len);
  writeU32LE(mem, hdrPtr + 12, dataPtr);
  return BigInt(hdrPtr) | TAG_OBJ;
}

function encodeHostBytes(instance, buf) {
  return hostUsesRawAbi()
    ? encodeHostBytesRaw(instance, buf)
    : encodeHostBytesTagged(instance, buf);
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

function decodeHostBytes(instance, value) {
  if (!hostUsesRawAbi()) {
    return decodeTaggedBytes(instance, value);
  }
  if (typeof value !== "bigint") {
    throw new Error(`expected raw bytes bigint, got ${typeof value}`);
  }
  const mem = new Uint8Array(instance.exports.memory.buffer);
  const rawPtr = Number(value);
  if (rawPtr >= 0 && rawPtr + 12 <= mem.length) {
    const len = readU32LE(mem, rawPtr + 4);
    const dataPtr = readU32LE(mem, rawPtr + 8);
    if (dataPtr >= 0 && dataPtr + len <= mem.length) {
      if (process.env.VIBE_DEBUG_BYTES === "1") {
        console.error(
          `[debug bytes] host abi=${HOST_IMPORT_ABI} raw_ptr=${rawPtr} len=${len} data_ptr=${dataPtr}`,
        );
        console.error(
          `[debug bytes] data[0..16]: ${Array.from(mem.slice(dataPtr, dataPtr + Math.min(len, 16))).map((b) => b.toString(16).padStart(2, "0")).join(" ")}`,
        );
      }
      return new Uint8Array(instance.exports.memory.buffer.slice(dataPtr, dataPtr + len));
    }
  }
  if (process.env.VIBE_DEBUG_BYTES === "1") {
    const raw = typeof value === "bigint" ? value : BigInt(value);
    const ptr = Number(raw);
    const lo = ptr >= 0 && ptr < mem.length ? ptr : 0;
    console.error(`[debug bytes] host abi=${HOST_IMPORT_ABI} value=${raw} ptr=${ptr}`);
    console.error(`[debug bytes] mem[value..value+32]: ${Array.from(mem.slice(lo, lo + 32)).map((b) => b.toString(16).padStart(2, "0")).join(" ")}`);
  }
  return decodeSelfhostPackedBytes(instance, value);
}

function taggedIntToText(tagged) {
  if ((tagged & TAG_MASK) === TAG_INT) {
    return (tagged >> 2n).toString();
  }
  return tagged.toString();
}

function readUlebAt(buf, pos, end = buf.length) {
  let value = 0;
  let shift = 0;
  let cursor = pos;
  while (cursor < end) {
    const byte = buf[cursor++];
    value += (byte & 0x7f) * (2 ** shift);
    if ((byte & 0x80) === 0) {
      return { value, next: cursor };
    }
    shift += 7;
    if (shift > 35) {
      throw new Error("ULEB128 value is too large");
    }
  }
  throw new Error("truncated ULEB128");
}

function parseKeyValueMetadata(text) {
  const out = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith("#")) {
      continue;
    }
    const eq = line.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return out;
}

function parseVibeAbiMetadata(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  if (
    buf.length < 8 ||
    buf[0] !== 0x00 ||
    buf[1] !== 0x61 ||
    buf[2] !== 0x73 ||
    buf[3] !== 0x6d
  ) {
    return null;
  }
  let pos = 8;
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    const sectionLenInfo = readUlebAt(buf, pos);
    pos = sectionLenInfo.next;
    const sectionEnd = pos + sectionLenInfo.value;
    if (sectionEnd > buf.length) {
      throw new Error("WASM section length exceeds input");
    }
    if (sectionId === 0) {
      const nameLenInfo = readUlebAt(buf, pos, sectionEnd);
      const nameStart = nameLenInfo.next;
      const nameEnd = nameStart + nameLenInfo.value;
      if (nameEnd > sectionEnd) {
        throw new Error("WASM custom section name exceeds section length");
      }
      const name = buf.slice(nameStart, nameEnd).toString("utf8");
      if (name === "vibe.abi") {
        const payload = buf.slice(nameEnd, sectionEnd).toString("utf8");
        return parseKeyValueMetadata(payload);
      }
    }
    pos = sectionEnd;
  }
  return null;
}

// #cov: parse the `vibe_cov` custom section emitted by coverage builds.
// Payload layout: i32 LE cov_base, i32 LE cov_count, then user-function names
// (one per line, in bitmap-index order). Returns {base, count, names} or null.
function parseVibeCovSection(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  if (
    buf.length < 8 ||
    buf[0] !== 0x00 ||
    buf[1] !== 0x61 ||
    buf[2] !== 0x73 ||
    buf[3] !== 0x6d
  ) {
    return null;
  }
  let pos = 8;
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    const sectionLenInfo = readUlebAt(buf, pos);
    pos = sectionLenInfo.next;
    const sectionEnd = pos + sectionLenInfo.value;
    if (sectionEnd > buf.length) {
      break;
    }
    if (sectionId === 0) {
      const nameLenInfo = readUlebAt(buf, pos, sectionEnd);
      const nameStart = nameLenInfo.next;
      const nameEnd = nameStart + nameLenInfo.value;
      const name = buf.slice(nameStart, nameEnd).toString("utf8");
      if (name === "vibe_cov" && nameEnd + 8 <= sectionEnd) {
        const base = buf.readUInt32LE(nameEnd);
        const count = buf.readUInt32LE(nameEnd + 4);
        const namesText = buf.slice(nameEnd + 8, sectionEnd).toString("utf8");
        const names = namesText.split("\n");
        if (names.length && names[names.length - 1] === "") {
          names.pop();
        }
        return { base, count, names };
      }
    }
    pos = sectionEnd;
  }
  return null;
}

// #cov branch: parse the `vibe_cov_branch` custom section. Payload: i32 LE base,
// i32 LE count, then count i32 LE owning-function-index entries (id order).
// Returns {base, count, owners:[fnIndex...]} or null.
function parseVibeCovBranchSection(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  if (buf.length < 8 || buf[0] !== 0x00 || buf[1] !== 0x61 || buf[2] !== 0x73 || buf[3] !== 0x6d) {
    return null;
  }
  let pos = 8;
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    const sectionLenInfo = readUlebAt(buf, pos);
    pos = sectionLenInfo.next;
    const sectionEnd = pos + sectionLenInfo.value;
    if (sectionEnd > buf.length) {
      break;
    }
    if (sectionId === 0) {
      const nameLenInfo = readUlebAt(buf, pos, sectionEnd);
      const nameStart = nameLenInfo.next;
      const nameEnd = nameStart + nameLenInfo.value;
      const name = buf.slice(nameStart, nameEnd).toString("utf8");
      if (name === "vibe_cov_branch" && nameEnd + 8 <= sectionEnd) {
        const base = buf.readUInt32LE(nameEnd);
        const count = buf.readUInt32LE(nameEnd + 4);
        const owners = [];
        let p = nameEnd + 8;
        for (let i = 0; i < count && p + 4 <= sectionEnd; i += 1) {
          owners.push(buf.readUInt32LE(p));
          p += 4;
        }
        return { base, count, owners };
      }
    }
    pos = sectionEnd;
  }
  return null;
}

function normalizeHostImportAbi(value) {
  if (value === "raw" || value === "tagged") {
    return value;
  }
  return null;
}

function detectHostImportAbi(wasmBytes) {
  try {
    const metadata = parseVibeAbiMetadata(wasmBytes);
    if (!metadata) {
      return null;
    }
    return normalizeHostImportAbi(metadata.host_import_abi);
  } catch (err) {
    if (process.env.VIBE_DEBUG_IMPORTS === "1") {
      console.error(`[vibe.abi] failed to parse metadata: ${err?.message || err}`);
    }
    return null;
  }
}

function buildFsMetadataHashParts(filePath) {
  const stat = fs.statSync(filePath, { bigint: true });
  const size = typeof stat.size === "bigint" ? stat.size : BigInt(stat.size);
  const mtimeNs =
    typeof stat.mtimeNs === "bigint"
      ? stat.mtimeNs
      : BigInt(Math.round(Number(stat.mtimeMs) * 1e6));
  // ino guards the "racy stat" window (same class as git's racy index): an
  // atomic rename-in rewrite that lands in the same kernel timestamp tick
  // with the same size would otherwise produce an identical token, so the
  // persistent source caches missed the change (persistent_cache_test's
  // invalidation assert caught this once compiles got fast enough to fit in
  // one tick). Every atomicWriteFileSync allocates a fresh inode, so mixing
  // it in makes rename-based rewrites always change the token. Must mirror
  // viberun's vibe_stat_token exactly (shared cache/cwasm keys).
  const ino = typeof stat.ino === "bigint" ? stat.ino : BigInt(stat.ino || 0);
  const lower = BigInt.asUintN(
    64,
    (size * 0x9e3779b185ebca87n) ^
      mtimeNs ^
      0x243f6a8885a308d3n ^
      (ino * 0x100000001b3n),
  );
  const upper = BigInt.asUintN(
    64,
    (mtimeNs << 1n) ^ (size << 17n) ^ 0x13198a2e03707344n ^ (ino << 7n),
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
        maxLen = toU32(maxLen);
        retptr = toU32(retptr);
        const desc = resolveDescriptor(handle);
        logDebug(`[preview2 fs] read handle=${handle} path=${desc.path} maxLen=${maxLen} offset=${offset}`);
        const file = fs.readFileSync(desc.path);
        const start = Number(offset);
        const end = Math.min(file.length, start + maxLen);
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
        dataPtr = toU32(dataPtr);
        dataLen = toU32(dataLen);
        retptr = toU32(retptr);
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
        const cacheDisabled = isPersistentArtifactCacheDisabled(filePath);
        const exists = !cacheDisabled && fs.existsSync(filePath);
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

  // M2c-3 (0.2 input-stream bridge): when VIBE_STDIN_BYTES is set, feed its
  // UTF-8 bytes to input-stream.blocking-read so a handler can consume a
  // host-provided byte stream incrementally (the testable stand-in for the WASI
  // 0.3 stream<u8> HTTP body; docs/spec/wasi-p3-async.md §3.3). Unset =>
  // legacy EOF behaviour, so existing tests are unaffected.
  const stdinFeed =
    process.env.VIBE_STDIN_BYTES !== undefined
      ? Buffer.from(process.env.VIBE_STDIN_BYTES, "utf8")
      : null;
  let stdinCursor = 0;

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
      "[method]input-stream.blocking-read"(handle, maxLen, retptr) {
        const instance = instanceRefGlobal;
        if (!(instance?.exports?.memory instanceof WebAssembly.Memory)) {
          throw new Error("missing exported memory for input-stream read");
        }
        // WIT signature is `blocking-read(len: u64)`, so `maxLen` arrives as a
        // BigInt; `handle`/`retptr` may also be BigInt. Normalize to numbers.
        const handleNum = Number(handle);
        const maxLenNum = Number(maxLen);
        const retptrNum = Number(retptr);
        // With VIBE_STDIN_BYTES set, serve the feed buffer incrementally
        // (respecting maxLen) so the guest's read loop drains a real
        // host-provided byte stream; EOF (empty ok list) once exhausted.
        if (
          stdinFeed !== null &&
          handleNum === STDIN_STREAM_HANDLE &&
          stdinCursor < stdinFeed.length
        ) {
          const want = Math.min(maxLenNum, stdinFeed.length - stdinCursor);
          const ptr = allocPreview2Buffer(instance, want, 1);
          const mem = new Uint8Array(instance.exports.memory.buffer);
          mem.set(stdinFeed.subarray(stdinCursor, stdinCursor + want), ptr);
          stdinCursor += want;
          // result<list<u8>, stream-error>: tag=0 (ok), then list { ptr, len }
          writeU8(mem, retptrNum, 0);
          writeU32LE(mem, retptrNum + 4, ptr);
          writeU32LE(mem, retptrNum + 8, want);
          return;
        }
        // Default / exhausted: signal EOF (empty list) so callers like
        // `Stdin::read_char` see `-1` and `read_line` returns "".
        const mem = new Uint8Array(instance.exports.memory.buffer);
        writeU8(mem, retptrNum, 0);
        writeU32LE(mem, retptrNum + 4, 0); // ptr
        writeU32LE(mem, retptrNum + 8, 0); // len
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
  for (let ptr = heapStart; ptr + 12 <= heapEnd; ptr += 4) {
    if (readU32LE(mem, ptr) === 7 && readU32LE(mem, ptr + 8) === tableSlot) {
      return ptr;
    }
  }
  return 0;
}

let instanceRefGlobal = null;
let covWasmBytesGlobal = null;
// #1007 review (Codex P2): exposes the REAL positional output arg (argv[1]
// as the compiled program sees it via Env::args_get) to the top-level catch
// handler below, which runs outside main()'s own scope. Set once, right
// after main() finalizes `passthroughArgs` (never reassigned afterward, so
// staleness in a --daemon/long-running context isn't a concern here — the
// stack-overflow catch only fires once, ending the process).
let passthroughArgsGlobal = null;

// #cov: dump the function/branch hit bitmaps from the (possibly trapped)
// instance's live memory to VIBE_COV_OUT. Called both after a clean run AND from
// the top-level catch — a compile that throws (parse/type error) still exercised
// many branches before unwinding, so capturing its coverage is essential for
// corpus/error-path measurement. Returns true if a report was written.
function dumpCoverage(reason) {
  const covOut = process.env.VIBE_COV_OUT;
  if (!covOut || !covWasmBytesGlobal) {
    return false;
  }
  const wasmBytes = covWasmBytesGlobal;
  const cov = parseVibeCovSection(wasmBytes);
  const mem = instanceRefGlobal?.exports?.memory;
  if (!cov || !mem) {
    return false;
  }
  const bytes = new Uint8Array(mem.buffer);
  const hitFns = [];
  const missedFns = [];
  for (let i = 0; i < cov.count; i += 1) {
    const nm = cov.names[i] ?? `#${i}`;
    if (bytes[cov.base + i]) {
      hitFns.push(nm);
    } else {
      missedFns.push(nm);
    }
  }
  const report = {
    total: cov.count,
    hit: hitFns.length,
    missed: missedFns.length,
    rate: cov.count ? hitFns.length / cov.count : 0,
    missed_fns: missedFns,
    hit_fns: hitFns,
  };
  const covb = parseVibeCovBranchSection(wasmBytes);
  if (covb) {
    let bhit = 0;
    const perFn = new Map();
    for (let i = 0; i < covb.count; i += 1) {
      const owner = covb.owners[i] ?? -1;
      const fnName = cov.names[owner] ?? `#${owner}`;
      const hit = bytes[covb.base + i] ? 1 : 0;
      bhit += hit;
      const e = perFn.get(fnName) ?? { total: 0, hit: 0 };
      e.total += 1;
      e.hit += hit;
      perFn.set(fnName, e);
    }
    const branchPerFn = {};
    const branchGaps = [];
    for (const [fn, e] of perFn) {
      branchPerFn[fn] = e;
      if (e.hit < e.total) {
        branchGaps.push({ fn, taken: e.hit, total: e.total });
      }
    }
    branchGaps.sort((a, b) => (b.total - b.taken) - (a.total - a.taken));
    report.branch = {
      total: covb.count,
      hit: bhit,
      missed: covb.count - bhit,
      rate: covb.count ? bhit / covb.count : 0,
      per_fn: branchPerFn,
      top_gaps: branchGaps.slice(0, 50),
    };
  }
  if (process.env.VIBE_COV_RAW === "1") {
    const fnBitmap = [];
    for (let i = 0; i < cov.count; i += 1) {
      fnBitmap.push(bytes[cov.base + i] ? 1 : 0);
    }
    report.raw = { fn_names: cov.names.slice(0, cov.count), fn_bitmap: fnBitmap };
    if (covb) {
      const brBitmap = [];
      for (let i = 0; i < covb.count; i += 1) {
        brBitmap.push(bytes[covb.base + i] ? 1 : 0);
      }
      report.raw.branch_owners = covb.owners;
      report.raw.branch_bitmap = brBitmap;
    }
  }
  fs.writeFileSync(covOut, `${JSON.stringify(report, null, 2)}\n`);
  const branchMsg = report.branch
    ? report.branch.total
      ? `, ${report.branch.hit}/${report.branch.total} branches taken (${(report.branch.rate * 100).toFixed(2)}%)`
      : ", 0 branches"
    : "";
  const tag = reason ? ` (${reason})` : "";
  console.error(
    `[vibe-cov]${tag} ${hitFns.length}/${cov.count} functions hit (${(report.rate * 100).toFixed(2)}%)${branchMsg} -> ${covOut}`,
  );
  return true;
}

function extractProfileRequest(args) {
  const req = {
    phase: null,
    profileTsv: null,
    callstackTsv: null,
  };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "compile-lite") {
      req.phase = "compile";
    } else if (arg === "check" || arg === "--check") {
      req.phase = "check";
    } else if (arg === "--profile-tsv" && i + 1 < args.length) {
      req.profileTsv = args[i + 1];
      i += 1;
    } else if (arg === "--profile-callstack" && i + 1 < args.length) {
      req.callstackTsv = args[i + 1];
      i += 1;
    }
  }
  return req;
}

function writeTextFileEnsuringDir(filePath, content) {
  if (!filePath) return;
  const resolved = path.resolve(process.cwd(), filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, content);
}

let profileMemoryMarkIndex = 0;

function emitProfileMemoryMark() {
  if (process.env.VIBE_PROFILE_MEMORY_MARKS !== "1" || !instanceRefGlobal) {
    return;
  }
  if (HOST_IMPORT_ABI !== "raw") {
    return;
  }
  const memory = instanceRefGlobal.exports.memory;
  const heapGlobal = instanceRefGlobal.exports.__heap_ptr;
  const heapRaw = heapGlobal instanceof WebAssembly.Global ? heapGlobal.value : null;
  const heapPtr =
    typeof heapRaw === "bigint"
      ? Number(BigInt.asUintN(64, heapRaw))
      : typeof heapRaw === "number"
        ? heapRaw >>> 0
        : heapRaw;
  const memoryBytes = memory instanceof WebAssembly.Memory ? memory.buffer.byteLength : 0;
  const memoryPages = memoryBytes / 65536;
  const hostAllocPtr = hostAllocPtrGlobal === null ? 0 : hostAllocPtrGlobal;
  const rss = process.memoryUsage().rss;
  console.error(
    `[profile-memory] mark=${profileMemoryMarkIndex} pages=${memoryPages} bytes=${memoryBytes} heap_ptr=${heapPtr ?? "missing"} host_alloc_ptr=${hostAllocPtr} rss=${rss}`,
  );
  profileMemoryMarkIndex += 1;
}

function maybeEmitEnvMemoryMark(name) {
  if (name === "VIBE_PROFILE_MEMORY_MARK") {
    emitProfileMemoryMark();
  }
}

function profileNowUs() {
  emitProfileMemoryMark();
  return Number((process.hrtime.bigint() - PROFILE_START_NS) / 1000n);
}

// Backs the `vibe.profile-heap-bytes` host import (Profiler::heap_bytes):
// the guest's current bump-heap pointer. The bump allocator never frees, so
// this is a monotonic allocation counter — deltas attribute allocation to a
// code region the same way now_us deltas attribute time.
function currentGuestHeapBytes() {
  const heapGlobal = instanceRefGlobal?.exports?.__heap_ptr;
  if (!(heapGlobal instanceof WebAssembly.Global)) {
    return 0;
  }
  const raw = heapGlobal.value;
  return typeof raw === "bigint" ? Number(BigInt.asUintN(64, raw)) : raw >>> 0;
}

function profileFileHasNonzeroStage(filePath, stage) {
  if (!filePath) return false;
  const resolved = path.resolve(process.cwd(), filePath);
  if (!fs.existsSync(resolved)) return false;
  const content = fs.readFileSync(resolved, "utf8");
  const prefix = `${stage}\t`;
  for (const line of content.split(/\r?\n/)) {
    if (!line.startsWith(prefix)) continue;
    const cols = line.split("\t");
    if (cols.length >= 3 && Number(cols[2]) > 0) return true;
  }
  return false;
}

function profileRowsForElapsed(phase, elapsedUs) {
  const us = Math.max(1, Math.round(elapsedUs));
  const ms = Math.floor(us / 1000);
  if (phase === "check") {
    return `stage\telapsed_ms\telapsed_us\nload\t0\t0\ntype\t${ms}\t${us}\ntotal\t${ms}\t${us}\n`;
  }
  const writeUs = us > 1 ? Math.max(1, Math.floor(us / 100)) : 1;
  const compileUs = Math.max(1, us - writeUs);
  const compileMs = Math.floor(compileUs / 1000);
  const writeMs = Math.floor(writeUs / 1000);
  return `stage\telapsed_ms\telapsed_us\nload\t0\t0\ntype\t0\t0\nparse\t0\t0\ncompile\t${compileMs}\t${compileUs}\nwrite\t${writeMs}\t${writeUs}\ntotal\t${ms}\t${us}\n`;
}

function callstackRowsForElapsed(phase, elapsedUs) {
  const us = Math.max(1, Math.round(elapsedUs));
  const ms = Math.floor(us / 1000);
  const stage = phase === "check" ? "check" : "compile";
  return `stage\telapsed_ms\telapsed_us\n${stage}\t${ms}\t${us}\n`;
}

function writeProfileRequest(req, elapsedUs) {
  if (!req.phase) return;
  if (req.profileTsv && !profileFileHasNonzeroStage(req.profileTsv, "total")) {
    writeTextFileEnsuringDir(req.profileTsv, profileRowsForElapsed(req.phase, elapsedUs));
  }
  if (req.callstackTsv && !profileFileHasNonzeroStage(req.callstackTsv, req.phase === "check" ? "check" : "compile")) {
    writeTextFileEnsuringDir(req.callstackTsv, callstackRowsForElapsed(req.phase, elapsedUs));
  }
}

async function main() {
  const {
    daemon,
    invokes,
    wasmPath,
    passthroughArgs: initialPassthroughArgs,
    benchCount,
    benchWarmup,
    benchSetup,
    invokeBatchDir,
  } = parseArgs(process.argv.slice(2));
  let passthroughArgs = initialPassthroughArgs.slice();
  passthroughArgsGlobal = passthroughArgs;
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
  covWasmBytesGlobal = wasmBytes;
  if (!REQUESTED_HOST_IMPORT_ABI) {
    const detectedAbi = detectHostImportAbi(wasmBytes);
    if (detectedAbi !== null) {
      HOST_IMPORT_ABI = detectedAbi;
    }
  }
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
    return encodeHostString(instanceRef, JSON.stringify(value));
  }

  function persistentArtifactCacheDisabled(filePath) {
    return isPersistentArtifactCacheDisabled(filePath);
  }

  // Linear-backend stdin feed for the `vibe.stdin_*` host imports (vibe/io).
  // Same VIBE_STDIN_BYTES source as the WASI 0.2 input-stream bridge in
  // createPreview2CliStreamsHost, but with its own cursor: a program uses one
  // backend, so the two never advance the same input concurrently. Unset =>
  // null => immediate EOF, matching the empty-stdin tests.
  const vibeStdinFeed =
    process.env.VIBE_STDIN_BYTES !== undefined
      ? Buffer.from(process.env.VIBE_STDIN_BYTES, "utf8")
      : null;
  let vibeStdinCursor = 0;

  // #794: HTTP client host state for the `vibe.http_*` imports behind
  // lib/@vibe/http's `__http_*_raw` builtins. `http_request` performs the whole
  // request SYNCHRONOUSLY in a child node process running fetch() (host imports
  // cannot suspend the guest here; same execSync pattern as `sh` above) and
  // parks the {status, headers, body} result in this map until http_close.
  const httpResponses = new Map();
  let nextHttpHandle = 1;

  // #865: structured subprocess result host state for `vibe.sh_capture*`,
  // behind lib/@vibe/process's `vibe_sh_capture_*_raw` builtins. `sh_capture`
  // runs the command ONCE (execSync with stdout/stderr captured separately
  // instead of `sh`'s stdio:"inherit" / `sh_lines`'s combined+"error: "-prefix
  // encoding) and parks {exitCode, stdout, stderr} in this map until
  // sh_capture_close -- same handle-map shape as httpResponses above, so the
  // 3 accessor imports are just cheap map reads (no re-exec).
  const shCaptureResults = new Map();
  let nextShCaptureHandle = 1;

  const vibeModule = new Proxy(
    {
      http_request(methodTagged, urlTagged, headersTagged, bodyTagged) {
        const method = decodeStringArg(instanceRef, methodTagged);
        const url = decodeStringArg(instanceRef, urlTagged);
        const headersText = decodeStringArg(instanceRef, headersTagged);
        const body = decodeStringArg(instanceRef, bodyTagged);
        // Child script: read one JSON request from stdin, fetch it, print one
        // JSON response (or {error}) to stdout. Header wire format matches
        // lib/@vibe/http's headers_to_wire: "Name: value" lines, "\n"-joined.
        const script = [
          'let input = "";',
          'process.stdin.on("data", (d) => { input += d; });',
          'process.stdin.on("end", async () => {',
          "  const req = JSON.parse(input);",
          "  const headers = {};",
          '  for (const line of req.headers.split("\\n")) {',
          '    const idx = line.indexOf(":");',
          "    if (idx > 0) headers[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();",
          "  }",
          "  try {",
          "    const res = await fetch(req.url, {",
          "      method: req.method,",
          "      headers,",
          '      body: req.method === "GET" || req.method === "HEAD" || req.body === "" ? undefined : req.body,',
          "    });",
          "    const text = await res.text();",
          "    const resHeaders = {};",
          "    res.headers.forEach((v, k) => { resHeaders[k] = v; });",
          "    process.stdout.write(JSON.stringify({ status: res.status, headers: resHeaders, body: text }));",
          "  } catch (e) {",
          "    process.stdout.write(JSON.stringify({ error: String((e && e.message) || e) }));",
          "  }",
          "});",
        ].join("\n");
        const out = cp.execFileSync(process.execPath, ["-e", script], {
          input: JSON.stringify({ method, url, headers: headersText, body }),
          encoding: "utf8",
          timeout: 60000,
        });
        const res = JSON.parse(out);
        if (res.error) {
          throw new Error(`http_request failed for '${url}': ${res.error}`);
        }
        const handle = nextHttpHandle;
        nextHttpHandle += 1;
        httpResponses.set(handle, res);
        if (process.env.VIBE_DEBUG_HTTP === "1") {
          console.error(
            `[http] ${method} ${url} -> handle=${handle} status=${res.status} body_len=${res.body.length}`,
          );
        }
        return encodeHostInt(handle);
      },
      http_response_status(handleTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_status: unknown response handle");
        }
        return encodeHostInt(entry.status);
      },
      http_response_header(handleTagged, nameTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_header: unknown response handle");
        }
        // fetch() lowercases header names; match case-insensitively.
        const name = decodeStringArg(instanceRef, nameTagged).toLowerCase();
        const value =
          entry.headers && entry.headers[name] !== undefined ? entry.headers[name] : "";
        return encodeHostString(instanceRef, value);
      },
      http_response_body(handleTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_body: unknown response handle");
        }
        return encodeHostString(instanceRef, entry.body);
      },
      // Tolerates unknown handles: `close` is shared by client and (future)
      // server surfaces, so a double-close must not kill the guest.
      http_close(handleTagged) {
        httpResponses.delete(decodeHostInt(handleTagged));
        return 0n;
      },
      sh(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        cp.execSync(cmd, { stdio: "inherit", shell: "/bin/bash" });
        return 0n;
      },
      sh_lines(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        try {
          const output = cp.execSync(cmd, { encoding: "utf-8", shell: "/bin/bash", stdio: ["pipe", "pipe", "pipe"] });
          return encodeHostString(instanceRef, output.trimEnd());
        } catch (e) {
          const stderr = e.stderr ? e.stderr.toString().trim() : e.message;
          return encodeHostString(instanceRef, "error: " + stderr);
        }
      },
      // #865: structured subprocess result behind lib/@vibe/process's
      // `sh_capture(cmd) -> ShResult`. Unlike `sh_lines` (combines
      // stdout+stderr into one packed string, and loses the real exit code
      // behind an "error: " string prefix on failure), this runs the command
      // ONCE via spawnSync -- which reports {status, stdout, stderr}
      // separately for BOTH the success and failure case (execSync only
      // returns stdout on success and throws on failure, so it can't give a
      // uniform success/failure shape without a try/catch that duplicates
      // the whole result plumbing) -- and parks the three fields behind a
      // handle so the 3 accessor calls below are cheap map reads, not re-execs.
      sh_capture(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        const res = cp.spawnSync(cmd, {
          shell: "/bin/bash",
          encoding: "utf-8",
          maxBuffer: 64 * 1024 * 1024,
        });
        let exitCode;
        let stderr = res.stderr || "";
        if (res.error) {
          // The shell/child itself failed to spawn (e.g. missing binary) --
          // no real exit code exists, so use the shell "command not found"
          // convention (127) and surface the spawn error on stderr.
          exitCode = 127;
          stderr = stderr || String((res.error && res.error.message) || res.error);
        } else if (res.signal) {
          // Killed by a signal rather than exiting normally; 128 is a
          // reasonable non-zero sentinel (we don't have a portable
          // signal-name -> number table here).
          exitCode = 128;
        } else {
          exitCode = res.status === null || res.status === undefined ? 1 : res.status;
        }
        const handle = nextShCaptureHandle;
        nextShCaptureHandle += 1;
        shCaptureResults.set(handle, {
          exitCode,
          stdout: res.stdout || "",
          stderr,
        });
        if (process.env.VIBE_DEBUG_SH === "1") {
          console.error(
            `[sh-capture] handle=${handle} exit=${exitCode} stdout_len=${(res.stdout || "").length} stderr_len=${stderr.length}`,
          );
        }
        return encodeHostInt(handle);
      },
      sh_capture_exit_code(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_exit_code: unknown handle");
        }
        return encodeHostInt(entry.exitCode);
      },
      sh_capture_stdout(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_stdout: unknown handle");
        }
        return encodeHostString(instanceRef, entry.stdout);
      },
      sh_capture_stderr(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_stderr: unknown handle");
        }
        return encodeHostString(instanceRef, entry.stderr);
      },
      // Tolerates unknown handles, like http_close above (a double-close
      // must not kill the guest).
      sh_capture_close(handleTagged) {
        shCaptureResults.delete(decodeHostInt(handleTagged));
        return 0n;
      },
      // #903/#865: propagate a guest-chosen exit code to the real OS exit
      // status -- unlike `main() -> Int`'s return value, which `_start`
      // only prints. `process.exit()` halts synchronously, so nothing
      // after this call in the guest ever runs; the return value below is
      // unreachable but kept for host-import type-signature consistency.
      process_exit(codeTagged) {
        process.exit(Number(decodeHostInt(codeTagged)));
        return 0n;
      },
      // vibe/io host effects (linear codegen `vibe.*` module). Both stdin
      // readers draw from the SAME VIBE_STDIN_BYTES feed + cursor as the WASI
      // 0.2 input-stream bridge (preview2CliStreamsHost), so a linear-backend
      // program reading stdin sees the runner's configured input rather than a
      // hardcoded EOF. With no VIBE_STDIN_BYTES the feed is null => immediate EOF
      // (read_char -> -1, read_stream -> ""), matching the empty-stdin tests.
      // write_stream/write_char echo to process stdout and return 0 (Unit).
      // Socket::tcp_connect/tcp_read/tcp_write/tcp_close -- mirrors
      // runtime/viberun's blocking std::net::TcpStream host imports (that
      // file's comment explains the "declared, zero codegen wiring" gap
      // this closes). Node has no synchronous TCP client, so the actual
      // net.Socket work runs on a worker thread
      // (wasm_vibe_host_runner_tcp_worker.js) and this thread blocks on
      // Atomics.wait() -- same blocking-bridge trick as `sleep` below, but
      // handing off to a worker instead of just parking this thread, since
      // an actual socket op needs Node's event loop running somewhere to
      // ever complete.
      tcp_connect(hostTagged, portTagged) {
        const host = decodeStringArg(instanceRef, hostTagged);
        const tcpPort = Number(decodeHostInt(portTagged));
        const handle = tcpWorkerCall("connect", { host, tcpPort });
        return encodeHostInt(handle);
      },
      tcp_read(handleTagged, maxBytesTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const maxBytes = Number(decodeHostInt(maxBytesTagged));
        const chunk = tcpWorkerCall("read", { handle, maxBytes });
        return encodeHostString(instanceRef, chunk);
      },
      tcp_write(handleTagged, dataTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const data = decodeStringArg(instanceRef, dataTagged);
        tcpWorkerCall("write", { handle, data });
        return 0n;
      },
      // Tolerates unknown handles, like fs_remove above -- a double-close
      // must not kill the guest (the worker's "close" handler no-ops on a
      // missing handle, same convention).
      tcp_close(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        tcpWorkerCall("close", { handle });
        return 0n;
      },
      // Http::request/response_status/response_header/response_body/close
      // (#1226) -- mirrors runtime/viberun's ureq-based host imports. Same
      // worker-thread + Atomics.wait bridge as tcp_* above (Node has no
      // synchronous HTTP client either), via
      // wasm_vibe_host_runner_http_worker.js.
      http_request(methodTagged, urlTagged, headersTagged, bodyTagged) {
        const method = decodeStringArg(instanceRef, methodTagged);
        const url = decodeStringArg(instanceRef, urlTagged);
        const headers = decodeStringArg(instanceRef, headersTagged);
        const body = decodeStringArg(instanceRef, bodyTagged);
        const handle = httpWorkerCall("request", { method, url, headers, body });
        return encodeHostInt(handle);
      },
      http_response_status(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const status = httpWorkerCall("status", { handle });
        return encodeHostInt(status);
      },
      http_response_header(handleTagged, nameTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const name = decodeStringArg(instanceRef, nameTagged);
        const value = httpWorkerCall("header", { handle, name });
        return encodeHostString(instanceRef, value);
      },
      http_response_body(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const body = httpWorkerCall("body", { handle });
        return encodeHostString(instanceRef, body);
      },
      // Tolerates unknown handles, like tcp_close above.
      http_close(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        httpWorkerCall("close", { handle });
        return 0n;
      },
      // `sleep(Int) -> Unit with Async` -- mirrors runtime/viberun's
      // `vibe.sleep` host import (see that impl's comment for why this is a
      // plain blocking sleep, not a true async/wasip3 one). Atomics.wait on
      // a throwaway SharedArrayBuffer blocks this thread synchronously,
      // same trick used for synchronous sleeps elsewhere in Node CLIs --
      // there's no way to `await` inside a synchronous WebAssembly import.
      sleep(msTagged) {
        const ms = Number(decodeHostInt(msTagged));
        if (ms > 0) {
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
        }
        return 0n;
      },
      stdin_read_char() {
        if (vibeStdinFeed && vibeStdinCursor < vibeStdinFeed.length) {
          const b = vibeStdinFeed[vibeStdinCursor];
          vibeStdinCursor += 1;
          return encodeHostInt(b);
        }
        return encodeHostInt(-1);
      },
      stdin_read_stream(nTagged) {
        const n = decodeHostInt(nTagged);
        if (!vibeStdinFeed || vibeStdinCursor >= vibeStdinFeed.length || n <= 0) {
          return encodeHostString(instanceRef, "");
        }
        const end = Math.min(vibeStdinFeed.length, vibeStdinCursor + n);
        const chunk = vibeStdinFeed.slice(vibeStdinCursor, end).toString("utf8");
        vibeStdinCursor = end;
        return encodeHostString(instanceRef, chunk);
      },
      stdout_write_stream(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        process.stdout.write(str);
        return 0n;
      },
      stdout_write_char(codeTagged) {
        const code = decodeHostInt(codeTagged);
        process.stdout.write(String.fromCharCode(code));
        return 0n;
      },
      // #865: Stderr, same shape as the Stdout pair above but writing to fd 2.
      stderr_write_stream(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        process.stderr.write(str);
        return 0n;
      },
      stderr_write_char(codeTagged) {
        const code = decodeHostInt(codeTagged);
        process.stderr.write(String.fromCharCode(code));
        return 0n;
      },
      path(pathValue) {
        const input = decodeStringArg(instanceRef, pathValue);
        return encodeHostString(instanceRef, input);
      },
      ["resolve-path"](pathTagged) {
        const input = decodeStringArg(instanceRef, pathTagged);
        return encodeHostString(instanceRef, input);
      },
      // #762: Path::ref / Path::resolve host op — resolve to an absolute path
      // against the process CWD (node path.resolve). Purely lexical: it does not
      // require the path to exist.
      resolve_path(pathTagged) {
        const input = decodeStringArg(instanceRef, pathTagged);
        return encodeHostString(instanceRef, path.resolve(input));
      },
      fs_read_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          const content = fs.readFileSync(filePath, "utf8");
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-read] ${filePath} bytes=${Buffer.byteLength(content, "utf8")}`);
          }
          return encodeHostString(instanceRef, content);
        } catch (e) {
          throw new Error(`fs_read_file failed for '${filePath}': ${e.message}`);
        }
      },
      // #632: read a file as raw bytes into a guest Bytes value. The exact
      // inverse of fs_write_bytes — unlike fs_read_file (utf8) it preserves
      // arbitrary binary, so the persistent artifact cache can store/load wasm
      // raw instead of hex (halving disk + dropping encode/decode).
      fs_read_bytes(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          const buf = fs.readFileSync(filePath);
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-read-bytes] ${filePath} bytes=${buf.length}`);
          }
          return encodeHostBytes(instanceRef, buf);
        } catch (e) {
          throw new Error(`fs_read_bytes failed for '${filePath}': ${e.message}`);
        }
      },
      // #729/#730: Fs::readdir — entry NAMES, byte-sorted, "\n"-joined into
      // ONE string over the same ABI as fs_read_file (raw + tagged both work;
      // codegen splits guest-side). The legacy fs_readdir above is
      // tagged-ABI-only (host-built array) and predates the selfhost raw ABI.
      // Empty dir -> "". Missing dir -> error, matching fs_read_file.
      fs_read_dir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          const entries = fs.readdirSync(dirPath);
          // Explicit byte-order comparison: JS default sort is UTF-16
          // code-unit order, which diverges from the Rust runner's byte sort
          // for non-ASCII names.
          entries.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
          return encodeHostString(instanceRef, entries.join("\n"));
        } catch (e) {
          throw new Error(`fs_read_dir failed for '${dirPath}': ${e.message}`);
        }
      },
      fs_exists(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        if (persistentArtifactCacheDisabled(filePath)) {
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-exists] artifact cache disabled: ${filePath}`);
          }
          return encodeHostBool(false);
        }
        const exists = fs.existsSync(filePath);
        if (process.env.VIBE_DEBUG_FS === "1") {
          console.error(`[fs-exists] ${filePath}=${exists ? "1" : "0"}`);
        }
        return encodeHostBool(exists);
      },
      fs_stat_token(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        // Module/package loading reserves -1 as a stable non-regular-source
        // witness. lstat is required here: stat would follow the link and make
        // a symlink indistinguishable from its target.
        if (fs.lstatSync(filePath).isSymbolicLink()) {
          return encodeHostInt(-1n);
        }
        const { lower, upper } = buildFsMetadataHashParts(filePath);
        return encodeHostInt(BigInt.asUintN(61, lower ^ upper));
      },
      fs_write_file(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        atomicWriteFileSync(filePath, content, "utf8");
        return 0n;
      },
      fs_publish_immutable_text(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        return encodeHostBool(publishImmutableTextSync(filePath, content));
      },
      fs_write_bytes(pathTagged, bytesTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const bytes = decodeHostBytes(instanceRef, bytesTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        atomicWriteFileSync(filePath, bytes);
        if (process.env.VIBE_DEBUG_FS === "1") {
          console.error(`[fs-write-bytes] ${filePath} bytes=${bytes.length}`);
        }
        return 0n;
      },
      fs_readdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          const entries = fs.readdirSync(dirPath);
          return encodeTaggedStringArray(instanceRef, entries);
        } catch (e) {
          return encodeTaggedStringArray(instanceRef, []);
        }
      },
      fs_getcwd() {
        return encodeHostString(instanceRef, process.cwd());
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
          return encodeHostBool(fs.statSync(filePath).isDirectory());
        } catch (e) {
          return encodeHostBool(false);
        }
      },
      fs_is_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          return encodeHostBool(fs.statSync(filePath).isFile());
        } catch (e) {
          return encodeHostBool(false);
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
        return encodeHostInt(fd);
      },
      fs_write_chunk(fdTagged, strTagged) {
        const fd = decodeHostInt(fdTagged);
        const str = decodeStringArg(instanceRef, strTagged);
        fs.writeSync(fd, str);
        return 0n;
      },
      fs_close_write(fdTagged) {
        const fd = decodeHostInt(fdTagged);
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
          return encodeHostString(instanceRef, JSON.stringify(parsed));
        } catch (e) {
          return encodeHostString(instanceRef, "null");
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
        return encodeHostString(instanceRef, value);
      },
      ["env-get"](nameTagged) {
        const name = decodeStringArg(instanceRef, nameTagged);
        maybeEmitEnvMemoryMark(name);
        const val = process.env[name] || "";
        if (process.env.VIBE_DEBUG_ENV === "1") {
          console.error(`[env-get] ${name}=${val}`);
        }
        return encodeHostString(instanceRef, val);
      },
      ["args-len"]() {
        return encodeHostInt(passthroughArgs.length);
      },
      ["args-get"](indexTagged) {
        const index = decodeHostInt(indexTagged);
        const val =
          index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
        if (process.env.VIBE_DEBUG_ENV === "1") {
          console.error(`[args-get] ${index}=${val}`);
        }
        return encodeHostString(instanceRef, val);
      },
      ["profile-now-us"]() {
        return encodeHostInt(profileNowUs());
      },
      ["profile-heap-bytes"]() {
        return encodeHostInt(currentGuestHeapBytes());
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
      profile_now_us() {
        return this["profile-now-us"]();
      },
      profile_heap_bytes() {
        return this["profile-heap-bytes"]();
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
      return encodeHostInt(passthroughArgs.length);
    },
    ArgsGet(indexTagged) {
      const index = decodeHostInt(indexTagged);
      const val =
        index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
      if (process.env.VIBE_DEBUG_ENV === "1") {
        console.error(`[ArgsGet] ${index}=${val}`);
      }
      return encodeHostString(instanceRef, val);
    },
    Get(nameTagged) {
      const name = decodeStringArg(instanceRef, nameTagged);
      maybeEmitEnvMemoryMark(name);
      const val = process.env[name] ?? "";
      if (process.env.VIBE_DEBUG_ENV === "1") {
        console.error(`[Get] ${name}=${val}`);
      }
      return encodeHostString(instanceRef, val);
    },
  };
  const fsModule = {
    ReadFile(pathTagged) {
      if (process.env.VIBE_DEBUG_FS === "1") {
        console.error("[fs-module] ReadFile");
      }
      return vibeModule.fs_read_file(pathTagged);
    },
    WriteFile(pathTagged, contentTagged) {
      return vibeModule.fs_write_file(pathTagged, contentTagged);
    },
    PublishImmutableText(pathTagged, contentTagged) {
      return vibeModule.fs_publish_immutable_text(pathTagged, contentTagged);
    },
    WriteBytes(pathTagged, bytesTagged) {
      return vibeModule.fs_write_bytes(pathTagged, bytesTagged);
    },
    ReadBytes(pathTagged) {
      return vibeModule.fs_read_bytes(pathTagged);
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
      return encodeHostString(instanceRef, "");
    },
    ReadChar() {
      // -1 indicates EOF.
      return encodeHostInt(-1);
    },
  };
  const stdoutModule = {
    WriteStream(strTagged) {
      const str = decodeStringArg(instanceRef, strTagged);
      process.stdout.write(str);
      return 0n;
    },
    WriteChar(codeTagged) {
      const code = decodeHostInt(codeTagged);
      process.stdout.write(String.fromCharCode(code));
      return 0n;
    },
  };
  // #1460 Phase 1: `Console` is the merged tty capability that replaces
  // Stdin/Stdout/Stderr.
  //
  // This module serves the PERFORM lowering only (`perform Console::WriteStream`),
  // which does name its import module after the effect. The linear backend --
  // the default one, and the path `vibe build --release` takes -- imports
  // `vibe.stdout_write_stream` instead: module "vibe", field derived from the
  // operation, effect label absent. So merging the three effects is not an ABI
  // change for it, and `Console::*` reuses the existing imports (see the note
  // in linked_compile.vibe). The legacy Stdin/Stdout modules below stay for
  // wasm the committed seed produced.
  const consoleModule = {
    ReadStream(maxBytesTagged) {
      return stdinModule.ReadStream(maxBytesTagged);
    },
    ReadChar() {
      return stdinModule.ReadChar();
    },
    WriteStream(strTagged) {
      return stdoutModule.WriteStream(strTagged);
    },
    WriteChar(codeTagged) {
      return stdoutModule.WriteChar(codeTagged);
    },
    WriteErrStream(strTagged) {
      const str = decodeStringArg(instanceRef, strTagged);
      process.stderr.write(str);
      return 0n;
    },
    WriteErrChar(codeTagged) {
      const code = decodeHostInt(codeTagged);
      process.stderr.write(String.fromCharCode(code));
      return 0n;
    },
  };
  const profilerModule = {
    NowUs(_envTagged) {
      return encodeHostInt(profileNowUs());
    },
    HeapBytes(_envTagged) {
      return encodeHostInt(currentGuestHeapBytes());
    },
  };

  const imports = new Proxy(
    {
      vibe: vibeModule,
      Env: envModule,
      Fs: fsModule,
      Profiler: profilerModule,
      Stdin: stdinModule,
      Stdout: stdoutModule,
      Console: consoleModule,
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
  preGrowWasmMemory(instance);
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
    // #799/#1182 perf+correctness: `cli_main` is the selfhost CLI's exported
    // main, and `main` is the ADR-0075 entry every ordinary `.vibex` program
    // uses -- on those artifacts the WASI-convention `_start` ALSO calls the
    // entry directly (see linked_compile.vibe's `_start` synthesis: when a
    // named entry is found it emits exactly `call entry_func_idx` once, no
    // loop). The pre-invoke `_start()` below (module init for test/bench
    // modules, where `_start` instead loops over every `test_*`/`bench_*`
    // export and does NOT call the single target being invoked) therefore
    // duplicated `cli_main`'s work (findClosureEnv then scanned the ~360MB
    // post-compile heap for an env cli_main does not have, and the explicit
    // cli_main call ran AGAIN) and, more seriously, for `main` it double-runs
    // every side effect the program performs (confirmed: a `.vibex` program
    // that writes one line to stdout via `vibe_run.sh` printed it twice).
    // Outputs are byte-identical for cli_main either way (verified); skip the
    // pre-start for both known single-entry names. VIBE_FORCE_RUN_INIT=1
    // restores the old (double-invoking) behavior for debugging.
    //
    // #819: `__test_<name>` / `__bench_<name>` are the per-block exports of a
    // `__no_entry__` test/bench build, and there `_start` IS the loop over all
    // of those blocks -- pre-running it would run EVERY block before the one
    // being invoked (a failing sibling would fail every per-block invoke, and
    // a merged N-file module would run the whole battery N times). There is no
    // module init to lose: a test module's `_start` contains only that loop,
    // and top-level non-function bindings are lazily-initialized thunk globals,
    // not a start-section side effect. The Rust runner's `--bench` mode already
    // calls these exports directly with env=0 (runtime/viberun/src/main.rs);
    // this makes the JS runner's `--invoke` agree.
    const isPerBlockExport =
      invoke.startsWith("__test_") || invoke.startsWith("__bench_");
    const skipRunInit =
      process.env.VIBE_SKIP_RUN_INIT === "1" ||
      ((invoke === "cli_main" || invoke === "main" || isPerBlockExport) &&
        process.env.VIBE_FORCE_RUN_INIT !== "1");
    let resolvedEnv = 0;
    if (!skipRunInit && invoke !== "_start" && typeof instance.exports._start === "function") {
      if (!didInitStart) {
        initHeapBeforeStart =
          instance.exports.__heap_ptr instanceof WebAssembly.Global
            ? instance.exports.__heap_ptr.value
            : 0;
        try {
          instance.exports._start();
        } catch (startErr) {
          if (process.env.VIBE_DEBUG708_MEMDUMP) {
            const mem708 = new Uint8Array(instance.exports.memory.buffer);
            const hp708g = instance.exports.__heap_ptr;
            const hp708 = hp708g instanceof WebAssembly.Global ? Number(hp708g.value) : mem708.length;
            require("fs").writeFileSync(process.env.VIBE_DEBUG708_MEMDUMP, Buffer.from(mem708.slice(0, Math.min(hp708 + 4096, mem708.length))));
            console.error(`[crash708] dumped ${Math.min(hp708 + 4096, mem708.length)} bytes to ${process.env.VIBE_DEBUG708_MEMDUMP}, heap_ptr=${hp708}`);
          }
          throw startErr;
        }
        didInitStart = true;
        const fsRootDescriptor = instance.exports.__fs_root_descriptor;
        if (fsRootDescriptor instanceof WebAssembly.Global) {
          fsRootDescriptor.value = -1;
        }
      }
      if (resolvedEnvCache.has(invoke)) {
        resolvedEnv = resolvedEnvCache.get(invoke);
      } else {
        const envExport = instance.exports[`__export_env_${invoke}`];
        const funcIdx = exportFuncIndices[invoke];
        const tableSlot = funcIdx !== undefined ? funcToTableSlot[funcIdx] : undefined;
        if (envExport instanceof WebAssembly.Global) {
          const value = envExport.value;
          resolvedEnv = typeof value === "bigint" ? Number(value) : value;
        } else {
          resolvedEnv =
            tableSlot !== undefined ? findClosureEnv(instance, initHeapBeforeStart, tableSlot) : 0;
        }
        if (process.env.VIBE_DEBUG_INVOKE_ENV === "1") {
          console.error(
            `[invoke-env] ${invoke} funcIdx=${funcIdx ?? "<missing>"} tableSlot=${tableSlot ?? "<missing>"} heapStart=${initHeapBeforeStart} heapEnd=${
              instance.exports.__heap_ptr instanceof WebAssembly.Global
                ? instance.exports.__heap_ptr.value
                : "<missing>"
            } envExport=${envExport instanceof WebAssembly.Global ? envExport.value : "<missing>"} resolvedEnv=${resolvedEnv}`,
          );
        }
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
      // #1262: walk the RC legacy free list (global 2, exported as
      // __rc_freelist) from the trap. Nodes are value pointers (block+8);
      // the size word lives at p-8 and the next link at p-4; 0 terminates.
      const flGlobal = instance.exports.__rc_freelist;
      if (flGlobal instanceof WebAssembly.Global && typeof hp === "number") {
        const dv = new DataView(instance.exports.memory.buffer);
        const heapLo = Number(process.env.VIBE_RC_HEAP_START || 58928);
        // #1262: a binary built from the size-word poison tree ORs 0x40000000
        // into the size word of every freed block. Mask it off for display —
        // leaving it in makes every healthy free-list node look corrupt.
        const poison = Number(process.env.VIBE_RC_POISON_MASK || 0);
        const rd = (a) => (a >= 0 && a + 4 <= mem.length ? dv.getUint32(a, true) : null);
        const rdsz = (a) => { const v = rd(a); return v === null ? null : (v & ~poison) >>> 0; };
        let p = flGlobal.value >>> 0;
        console.error(`[crash debug] __rc_freelist head=${p} (0x${p.toString(16)})`);
        const seen = new Set();
        let n = 0;
        let verdict = "clean (terminated at 0)";
        while (p !== 0) {
          if (p < heapLo + 8 || p > hp) {
            verdict = `OUT OF HEAP at node ${n}: p=${p} (0x${p.toString(16)}) not in [${heapLo + 8}, ${hp}]`;
            break;
          }
          if (seen.has(p)) { verdict = `CYCLE at node ${n}: p=${p} seen before`; break; }
          seen.add(p);
          const sz = rdsz(p - 8), nx = rd(p - 4);
          // __rt_arr_new asks for 84 bytes (84 & 7 == 4), so the bump pointer
          // is not always 8-aligned -- low3 != 0 is reported, not fatal.
          if (n < 24 || (p & 7)) {
            console.error(`[crash debug]   fl[${n}] p=${p} low3=${p & 7} size=${sz} next=${nx}`);
          }
          if (n < 6 && process.env.VIBE_RC_FL_WINDOW) {
            const lo = Math.max(0, p - 32), hi = Math.min(mem.length, p + 64);
            const w = Array.from(mem.slice(lo, hi));
            const hex = w.map(b => b.toString(16).padStart(2, "0")).join(" ");
            const asc = w.map(b => (b >= 32 && b < 127 ? String.fromCharCode(b) : ".")).join("");
            console.error(`[crash debug]     win[${n}] ${lo}..${hi} hex=${hex}`);
            console.error(`[crash debug]     win[${n}] ascii=${asc}`);
          }
          if (sz === null || nx === null) { verdict = `UNREADABLE header at node ${n}: p=${p}`; break; }
          p = nx >>> 0;
          n += 1;
          if (n > 4000000) { verdict = `TOO LONG (>4M nodes), last p=${p}`; break; }
        }
        console.error(`[crash debug] __rc_freelist: ${n} nodes walked -> ${verdict}`);
        if (verdict.indexOf("clean") !== 0) {
          const b = p >>> 0;
          console.error(`[crash debug] bad link raw=${b} hex=0x${b.toString(16)} low3=${b & 7} as_untagged_int=${b >> 1}`);
        }
      }
      if (process.env.VIBE_DEBUG708_MEMDUMP) {
        require("fs").writeFileSync(process.env.VIBE_DEBUG708_MEMDUMP, Buffer.from(mem.slice(0, typeof hp === "number" ? hp + 4096 : mem.length)));
        console.error(`[crash debug] full memory dumped to ${process.env.VIBE_DEBUG708_MEMDUMP} (${typeof hp === "number" ? hp + 4096 : mem.length} bytes)`);
      }
      throw err;
    }
  };
  const resultToExitCode = (result, isSelfhost) => {
    if (typeof result === "bigint") {
      // Selfhost-compiled modules return untagged i64 values (same split as
      // emitResult). Treating them as tagged shifted any multiple-of-4 exit
      // code right by 2 (main returning 20 exited 5).
      if (isSelfhost) {
        return Number(result) | 0;
      }
      return decodeTaggedOrRawInt(result);
    }
    if (typeof result === "number") {
      return result | 0;
    }
    return 0;
  };

  const emitResult = (invoke, result, isSelfhost) => {
    // #819: a per-block `__test_`/`__bench_` entry is "run this block", not
    // "evaluate this and report the value" -- codegen gives every one of them
    // the same `ESeq(body, EInt(0))` shape, so the result is a constant 0 that
    // carries no information. Printing it would append a stray `0` line to the
    // block's own stdout, which the doctest harness compares against the
    // embedded ```output block. `_start` doesn't print it either.
    if (invoke.startsWith("__test_") || invoke.startsWith("__bench_")) {
      return;
    }
    if (typeof result === "bigint") {
      // Check if the result is a tagged object (could be Bytes from selfbuild)
      if (
        (result & TAG_MASK) === TAG_OBJ &&
        (invoke === "selfbuild_compile_stage2" ||
          invoke === "selfbuild_compile_cli_adapter")
      ) {
        // Decode result as Bytes and write to expected output path
        const bytes = decodeHostBytes(instanceRef, result);
        const outPath =
          invoke === "selfbuild_compile_cli_adapter"
            ? "_build/bench/cli_adapter/cli_stage1.wasm"
            : "_build/bench/wasi_selfbuild/index_stage2.wasm";
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
  };

  const runInvokes = (args) => {
    passthroughArgs = args.slice();
    passthroughArgsGlobal = passthroughArgs;
    const profileRequest = extractProfileRequest(passthroughArgs);
    const profileStartNs = process.hrtime.bigint();
    let result;
    let isSelfhost = false;
    for (const invoke of invokes) {
      ({ result, isSelfhost } = invokeExport(invoke));
    }
    const elapsedUs = Number(process.hrtime.bigint() - profileStartNs) / 1000;
    writeProfileRequest(profileRequest, elapsedUs);
    return { result, isSelfhost, elapsedUs };
  };

  // #819/#141: run EVERY `--invoke` target in one process, keeping each one's
  // output separate.
  //
  // The doctest harness compiles a doc's blocks into a single module (#819)
  // and then invoked one `__test_<block>` export per block -- one node process
  // each, ~61ms of process+instantiate overhead apiece that has nothing to do
  // with the block. `--invoke` was always repeatable, but a plain repeat
  // concatenates every target's stdout into one stream, and the harness has to
  // compare EACH block's stdout against its own ```output. So the split is the
  // whole feature: target i's stdout, stderr and status land in
  // `<dir>/<i>.{out,err,rc}`, 1-based in flag order.
  //
  // Files rather than in-band delimiters on purpose: a block's stdout is
  // arbitrary doc output, so any marker line could legitimately appear inside
  // it and there is no escaping layer to lean on.
  //
  // Sequential invokes share one instance, which is exactly what `_start` does
  // for a test module (it loops over every `test_*` export in the same
  // instance), so this is the established semantics rather than a new one. A
  // failing target does NOT stop the batch -- its `rc` is 1 and the next one
  // runs -- but a target that dies hard enough to take the process with it
  // simply leaves later `.rc` files absent, which callers read as "not run"
  // and fall back to running those alone.
  const runInvokeBatch = (args, dir) => {
    passthroughArgs = args.slice();
    passthroughArgsGlobal = passthroughArgs;
    fs.mkdirSync(dir, { recursive: true });
    const originalStdoutWrite = process.stdout.write;
    const originalStderrWrite = process.stderr.write;
    let anyFailed = false;
    for (let i = 0; i < invokes.length; i += 1) {
      let out = "";
      let err = "";
      const capture = (append) => (chunk, encoding, callback) => {
        if (typeof encoding === "function") {
          callback = encoding;
        }
        append(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk));
        if (typeof callback === "function") {
          callback();
        }
        return true;
      };
      let rc = 0;
      process.stdout.write = capture((t) => {
        out += t;
      });
      process.stderr.write = capture((t) => {
        err += t;
      });
      try {
        const { result, isSelfhost } = invokeExport(invokes[i]);
        // A per-block export carries no result (emitResult returns early for
        // `__test_`/`__bench_`); for anything else this keeps batch mode's
        // stdout the same as a single-invoke run's.
        emitResult(invokes[i], result, isSelfhost);
      } catch (e) {
        rc = 1;
        err += `${decodeExceptionMessage(e)}\n`;
      } finally {
        process.stdout.write = originalStdoutWrite;
        process.stderr.write = originalStderrWrite;
      }
      const slot = String(i + 1);
      fs.writeFileSync(path.join(dir, `${slot}.out`), out);
      fs.writeFileSync(path.join(dir, `${slot}.err`), err);
      fs.writeFileSync(path.join(dir, `${slot}.rc`), `${rc}\n`);
      if (rc !== 0) {
        anyFailed = true;
      }
    }
    return anyFailed;
  };

  const decodeExceptionMessage = (err) => {
    if (!(err instanceof WebAssembly.Exception) || !instanceRefGlobal) {
      return err?.message || String(err);
    }
    for (const exp of Object.values(instanceRefGlobal.exports)) {
      if (exp instanceof WebAssembly.Tag) {
        try {
          const payload = err.getArg(exp, 0);
          const msg = tryDecodeExceptionString(instanceRefGlobal, payload);
          if (msg !== null) {
            return msg;
          }
        } catch (_) {}
      }
    }
    return err?.message || String(err);
  };

  const emitWasmMemoryStats = (label) => {
    if (process.env.VIBE_WASM_MEMORY_STATS !== "1") {
      return;
    }
    if (HOST_IMPORT_ABI !== "raw") {
      console.error(`[wasm-memory] ${label} skipped abi=${HOST_IMPORT_ABI}`);
      return;
    }
    const memory = instance.exports.memory;
    if (!(memory instanceof WebAssembly.Memory)) {
      console.error(`[wasm-memory] ${label} memory=missing`);
      return;
    }
    const heapGlobal = instance.exports.__heap_ptr;
    const heapRaw = heapGlobal instanceof WebAssembly.Global ? heapGlobal.value : null;
    const heapPtr =
      typeof heapRaw === "bigint"
        ? Number(BigInt.asUintN(64, heapRaw))
        : typeof heapRaw === "number"
          ? heapRaw >>> 0
          : heapRaw;
    const memoryBytes = memory.buffer.byteLength;
    const memoryPages = memoryBytes / 65536;
    const hostAllocPtr = hostAllocPtrGlobal === null ? 0 : hostAllocPtrGlobal;
    const rss = process.memoryUsage().rss;
    console.error(
      `[wasm-memory] ${label} pages=${memoryPages} bytes=${memoryBytes} heap_ptr=${heapPtr ?? "missing"} host_alloc_ptr=${hostAllocPtr} rss=${rss}`,
    );
  };

  // Daemon responses report the bump-allocator high-water (same source as
  // emitWasmMemoryStats) so a batch driver can recycle the process before the
  // never-freed heap approaches the wasm32 4GB memory ceiling.
  const readHeapPtr = () => {
    const heapGlobal = instance.exports.__heap_ptr;
    const heapRaw = heapGlobal instanceof WebAssembly.Global ? heapGlobal.value : null;
    if (typeof heapRaw === "bigint") {
      return Number(BigInt.asUintN(64, heapRaw));
    }
    return typeof heapRaw === "number" ? heapRaw >>> 0 : 0;
  };

  const runDaemon = async () => {
    if (benchCount !== null) {
      throw new Error("--daemon cannot be combined with --bench-count");
    }
    if (invokes.length !== 1) {
      throw new Error("--daemon requires exactly one --invoke target");
    }
    const rl = readline.createInterface({
      input: process.stdin,
      crlfDelay: Infinity,
    });
    const originalStdoutWrite = process.stdout.write;
    const writeResponse = originalStdoutWrite.bind(process.stdout);
    for await (const line of rl) {
      const row = line.trim();
      if (row.length === 0) {
        continue;
      }
      let capturedStdout = "";
      let response;
      process.stdout.write = (chunk, encoding, callback) => {
        if (typeof encoding === "function") {
          callback = encoding;
        }
        capturedStdout += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
        if (typeof callback === "function") {
          callback();
        }
        return true;
      };
      try {
        const req = JSON.parse(row);
        const args = Array.isArray(req.args) ? req.args.map(String) : [];
        const { result, isSelfhost, elapsedUs } = runInvokes(args);
        response = {
          exit_code: resultToExitCode(result, isSelfhost),
          elapsed_us: Math.max(1, Math.round(elapsedUs)),
          stdout: capturedStdout,
          heap_ptr: readHeapPtr(),
        };
      } catch (err) {
        response = {
          exit_code: 1,
          elapsed_us: 1,
          stdout: capturedStdout,
          error: decodeExceptionMessage(err),
        };
      } finally {
        process.stdout.write = originalStdoutWrite;
      }
      writeResponse(`${JSON.stringify(response)}\n`);
    }
  };

  if (daemon) {
    if (invokeBatchDir !== null) {
      throw new Error("--daemon cannot be combined with --invoke-batch-dir");
    }
    await runDaemon();
    return;
  }

  if (invokeBatchDir !== null) {
    if (benchCount !== null) {
      throw new Error("--invoke-batch-dir cannot be combined with --bench-count");
    }
    const anyFailed = runInvokeBatch(passthroughArgs, invokeBatchDir);
    emitWasmMemoryStats("run");
    process.exitCode = anyFailed ? 1 : 0;
    return;
  }

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
    emitWasmMemoryStats("bench");
    console.log(String(elapsedUs));
    return;
  }
  const { result, isSelfhost } = runInvokes(passthroughArgs);
  emitWasmMemoryStats("run");
  // #cov: after running an instrumented build, dump the hit bitmaps.
  if (process.env.VIBE_COV_OUT) {
    if (!dumpCoverage(null)) {
      console.error("[vibe-cov] no vibe_cov section or memory; not a coverage build?");
    }
  }
  const invoke = invokes[invokes.length - 1];
  emitResult(invoke, result, isSelfhost);
  if (invoke === "cli_main" || process.env.VIBE_RUNNER_EXIT_WITH_RESULT === "1") {
    process.exitCode = resultToExitCode(result, isSelfhost);
  }
}

if (require.main === module) {
main().catch((err) => {
  // #946(4): a pathologically deep expression (e.g. thousands of chained
  // `+`) recurses the checker (itself compiled to wasm) past the native call
  // stack. That blows up the whole wasm instance -- nothing inside the
  // compiled program's own `handle {...} with Exception {...}` can intercept a
  // host-level stack overflow, so it used to surface as a raw uncaught-
  // exception crash dump, which the `vibe check`/`vibe diagnostics` shell
  // wrappers (`>/dev/null 2>&1 || true`) silently swallowed into "clean".
  // Intercept it here instead and write the same `.diag` sidecar the
  // adapter's own error paths use (cli_adapter.vibe's
  // emit_compile_diag), so those commands can report a real (if unlocated)
  // diagnostic.
  //
  // #1007 review (Codex P2): read_arg_or_env (cli_adapter.vibe)
  // prefers the POSITIONAL arg (Env::args_get) over the env var, only
  // falling back to VIBE_OUTPUT when the arg is absent -- `runtime/vibe`
  // never unsets an inherited VIBE_OUTPUT before invoking the runner, so
  // preferring the env var here (as the first cut did) could write the
  // sidecar beside a stale inherited path while the compiled program itself
  // (and the shell script waiting on `$out.diag`) used the real positional
  // one, silently losing the diagnostic all over again. Match
  // read_arg_or_env's precedence: positional arg (passthroughArgsGlobal[1])
  // first.
  if (err instanceof RangeError && /call stack/i.test(err.message || "")) {
    const outputPath =
      (passthroughArgsGlobal && passthroughArgsGlobal[1]) ||
      process.env.VIBE_OUTPUT;
    if (outputPath) {
      try {
        fs.writeFileSync(`${outputPath}.diag`, "expression too deeply nested (stack overflow while type-checking)\n");
      } catch (_) {}
    }
    console.error("[vibe] stack overflow: expression too deeply nested");
    process.exit(1);
  }
  // #cov: even a failed run (parse/type error, trap) exercised many branches
  // before unwinding — capture its coverage from the still-live instance memory.
  try {
    dumpCoverage("aborted");
  } catch (_) {}
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
  // usage() is only relevant for argument-parsing errors. Runtime errors
  // (wasm traps, exceptions, etc.) drop straight to the stack trace so the
  // failing test output points at the real cause.
  if (instanceRefGlobal === null) {
    usage();
  }
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
}

module.exports = { publishImmutableTextSync };
