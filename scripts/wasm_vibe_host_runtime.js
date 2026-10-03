"use strict";

// One runtime per runner: host functions close over its mutable guest state.
function createHostRuntime() {

const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const crypto = require("node:crypto");
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
    "usage: node scripts/wasm_vibe_host_runner.js [--policy-stat-token content-v1 --policy-stat-root <absolute-root> [--policy-raw-fs-root <absolute-root> --policy-raw-fs-write-root <absolute-root>]] [--daemon] [--invoke <name>]... [--invoke-batch-dir <dir>] [--bench-count <n> --bench-warmup <n> --bench-setup <name>] <module.wasm> [argv...]",
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
  let policyStatToken = null;
  let policyStatRoot = null;
  let policyRawFsRoot = null;
  let policyRawFsWriteRoot = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--daemon") {
      daemon = true;
      continue;
    }
    if (arg === "--policy-stat-token") {
      if (wasmPath !== null || i + 1 >= argv.length || policyStatToken !== null) {
        throw new Error("--policy-stat-token requires one pre-wasm value");
      }
      policyStatToken = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--policy-stat-root") {
      if (wasmPath !== null || i + 1 >= argv.length || policyStatRoot !== null) {
        throw new Error("--policy-stat-root requires one pre-wasm value");
      }
      policyStatRoot = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--policy-raw-fs-root") {
      if (wasmPath !== null || i + 1 >= argv.length || policyRawFsRoot !== null) {
        throw new Error("--policy-raw-fs-root requires one pre-wasm value");
      }
      policyRawFsRoot = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--policy-raw-fs-write-root") {
      if (wasmPath !== null || i + 1 >= argv.length || policyRawFsWriteRoot !== null) {
        throw new Error("--policy-raw-fs-write-root requires one pre-wasm value");
      }
      policyRawFsWriteRoot = argv[i + 1];
      i += 1;
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
  if ((policyStatToken === null) !== (policyStatRoot === null)) {
    throw new Error("--policy-stat-token and --policy-stat-root must be supplied together");
  }
  if (policyStatToken !== null && policyStatToken !== "content-v1") {
    throw new Error(`unsupported --policy-stat-token: ${policyStatToken}`);
  }
  if (policyRawFsRoot !== null && policyStatToken !== "content-v1") {
    throw new Error("--policy-raw-fs-root requires content-v1 policy mode");
  }
  if ((policyRawFsRoot === null) !== (policyRawFsWriteRoot === null)) {
    throw new Error("--policy-raw-fs-root and --policy-raw-fs-write-root must be supplied together");
  }
  if (invokes.length === 0) {
    invokes.push("_start");
  }
  return {
    daemon,
    invokes,
    wasmPath,
    passthroughArgs,
    benchCount,
    benchWarmup,
    benchSetup,
    invokeBatchDir,
    policyStatToken,
    policyStatRoot,
    policyRawFsRoot,
    policyRawFsWriteRoot,
  };
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

// Match guest geometric growth, retrying the exact deficit at a capacity limit.
function growHostMemory(memory, pagesNeeded) {
  const currentPages = memory.buffer.byteLength / WASM_PAGE_BYTES;
  const growBy = Math.max(pagesNeeded, Math.floor(currentPages / 2));
  try {
    memory.grow(growBy);
  } catch (error) {
    if (!(error instanceof RangeError) || growBy === pagesNeeded) throw error;
    memory.grow(pagesNeeded);
  }
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
  growHostMemory(memory, pagesNeeded);
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
    growHostMemory(instance.exports.memory, pagesNeeded);
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
    growHostMemory(instance.exports.memory, pagesNeeded);
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
    growHostMemory(instance.exports.memory, pagesNeeded);
    mem = new Uint8Array(instance.exports.memory.buffer);
  }
  hostAllocPtrGlobal = next;
  return alignedPtr;
}

// A vibe string/bytes value is the fat pointer `(ptr << 32) | len` carried in an
// i64. The JS-API hands an i64 to the host as a SIGNED BigInt, so as soon as the
// guest allocates past 2 GiB the pointer's bit 31 is set, bit 63 of the packed
// value is set, and an arithmetic `>> 32n` yields a NEGATIVE pointer. Reinterpret
// the whole word as unsigned first: below 2 GiB this is the identity, above it it
// is the difference between working and `string range out of bounds`.
//
// This is load-bearing for real workloads, not a theoretical edge: an FS-mode
// compile of the whole CLI (`scripts/build_cli_core.sh`) with a COLD type-env
// cache peaks around 2.6-2.7 GiB, and died on the very last write (the
// `.funcmap` sidecar) after having produced a correct 22 MB wasm. A warm cache
// stays under 2 GiB, which is why it reads as flaky.
function unpackFatPointer(packed) {
  const bits = BigInt.asUintN(64, packed);
  return { ptr: Number(bits >> 32n), len: Number(bits & 0xffffffffn) };
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

  const { ptr, len } = unpackFatPointer(tagged);
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
  const { ptr, len } = unpackFatPointer(packed);
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
  const { ptr, len } = unpackFatPointer(packed);
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

const WASM_PAGE_BYTES = 65536;
const WASM32_ADDRESS_SPACE_BYTES = 4 * 1024 * 1024 * 1024;

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

// #2876: the declared maximum of the module's own memory, in BYTES -- what a
// growth request actually stops at, and so the only number a daemon can
// measure its remaining address space against.
//
// Returns null for a shape this does not model: a malformed header, or a
// memory64 memory, whose cap is nowhere near 4 GiB and whose limits are u64.
// Declining is not the same as guessing -- the caller leaves the failure
// unclassified rather than calling something "out of memory" that is not.
// A module with no memory section (an IMPORTED memory) still gets the wasm32
// architectural cap, because every wasm32 memory has it.
function parseWasmMemoryLimitBytes(wasmBytes) {
  try {
    return parseWasmMemoryLimitBytesUnguarded(wasmBytes);
  } catch (_) {
    // readUlebAt throws on a malformed LEB. Declining is the whole contract
    // here, so a module this cannot read must not take the runner down with it.
    return null;
  }
}

function parseWasmMemoryLimitBytesUnguarded(wasmBytes) {
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
    if (sectionId === 5) {
      const countInfo = readUlebAt(buf, pos, sectionEnd);
      if (countInfo.value < 1 || countInfo.next >= sectionEnd) {
        return null;
      }
      const flags = buf[countInfo.next];
      if ((flags & 0x04) !== 0) {
        return null;
      }
      const minInfo = readUlebAt(buf, countInfo.next + 1, sectionEnd);
      if ((flags & 0x01) === 0) {
        return WASM32_ADDRESS_SPACE_BYTES;
      }
      const maxInfo = readUlebAt(buf, minInfo.next, sectionEnd);
      return Math.min(maxInfo.value * WASM_PAGE_BYTES, WASM32_ADDRESS_SPACE_BYTES);
    }
    pos = sectionEnd;
  }
  return WASM32_ADDRESS_SPACE_BYTES;
}

// #2199: parse `vibe.dbgfiles` (source paths, one per line) and
// `vibe.linemap` (the 4-byte marker `VLM1`, then compact LEB deltas:
// func_delta, offset_delta, file_id, line per unique (func, offset)). Used to
// annotate an uncaught trap with an editable path:line. Missing/empty/
// stripped sections => no annotation, never a fabricated location.
//
// The marker is required: #644's table under the same section name was
// 16-byte little-endian records, which decode as LEB quadruples without
// erroring, so an older module would annotate with fabricated values. An
// unmarked table reads as empty.
function findWasmCustomSection(wasmBytes, wantName) {
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
      if (nameEnd <= sectionEnd) {
        const name = buf.slice(nameStart, nameEnd).toString("utf8");
        if (name === wantName) {
          return buf.slice(nameEnd, sectionEnd);
        }
      }
    }
    pos = sectionEnd;
  }
  return null;
}

function parseVibeDbgfiles(wasmBytes) {
  const payload = findWasmCustomSection(wasmBytes, "vibe.dbgfiles");
  if (!payload) {
    return [];
  }
  return payload.toString("utf8").split("\n").filter((l) => l.length > 0);
}

const LINEMAP_MAGIC = "VLM1";

function parseCompactLinemapPayload(payload) {
  const rows = [];
  if (!payload || payload.length < LINEMAP_MAGIC.length) {
    return rows;
  }
  if (payload.slice(0, LINEMAP_MAGIC.length).toString("latin1") !== LINEMAP_MAGIC) {
    return rows;
  }
  let pos = LINEMAP_MAGIC.length;
  const end = payload.length;
  const uleb = () => {
    let result = 0;
    let shift = 0;
    while (pos < end) {
      const byte = payload[pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) {
        return result >>> 0;
      }
      shift += 7;
      if (shift > 35) {
        return null;
      }
    }
    return null;
  };
  let func = 0;
  let offset = 0;
  let have = false;
  while (pos < end) {
    const fd = uleb();
    const od = uleb();
    const fileId = uleb();
    const line = uleb();
    if (fd === null || od === null || fileId === null || line === null) {
      break;
    }
    if (have && fd === 0) {
      offset += od;
    } else {
      func = have ? func + fd : fd;
      offset = od;
      have = true;
    }
    rows.push({ funcIdx: func, offset, fileId, line });
  }
  return rows;
}

function parseVibeLinemap(wasmBytes) {
  const payload = findWasmCustomSection(wasmBytes, "vibe.linemap");
  const byFunc = new Map();
  if (!payload) {
    return byFunc;
  }
  for (const rec of parseCompactLinemapPayload(payload)) {
    let entries = byFunc.get(rec.funcIdx);
    if (!entries) {
      entries = [];
      byFunc.set(rec.funcIdx, entries);
    }
    entries.push({ offset: rec.offset, fileId: rec.fileId, line: rec.line });
  }
  for (const entries of byFunc.values()) {
    entries.sort((a, b) => a.offset - b.offset);
  }
  return byFunc;
}

function parseWasmFuncEntryStarts(wasmBytes) {
  const buf = Buffer.from(wasmBytes);
  if (buf.length < 8 || buf[0] !== 0x00 || buf[1] !== 0x61 || buf[2] !== 0x73 || buf[3] !== 0x6d) {
    return { nimported: 0, starts: [] };
  }
  let pos = 8;
  let nimported = 0;
  let starts = [];
  while (pos < buf.length) {
    const sectionId = buf[pos++];
    const sectionLenInfo = readUlebAt(buf, pos);
    pos = sectionLenInfo.next;
    const sectionEnd = pos + sectionLenInfo.value;
    if (sectionEnd > buf.length) {
      break;
    }
    if (sectionId === 2) {
      const countInfo = readUlebAt(buf, pos, sectionEnd);
      let q = countInfo.next;
      for (let i = 0; i < countInfo.value && q < sectionEnd; i += 1) {
        const ml = readUlebAt(buf, q, sectionEnd);
        q = ml.next + ml.value;
        const nl = readUlebAt(buf, q, sectionEnd);
        q = nl.next + nl.value;
        const kind = buf[q++];
        if (kind === 0) {
          nimported += 1;
          const t = readUlebAt(buf, q, sectionEnd);
          q = t.next;
        } else {
          break;
        }
      }
    } else if (sectionId === 10) {
      const countInfo = readUlebAt(buf, pos, sectionEnd);
      let q = countInfo.next;
      for (let i = 0; i < countInfo.value && q < sectionEnd; i += 1) {
        const sz = readUlebAt(buf, q, sectionEnd);
        starts.push(sz.next);
        q = sz.next + sz.value;
      }
    }
    pos = sectionEnd;
  }
  return { nimported, starts };
}

function resolveLinemap(byFunc, funcIdx, offset) {
  const entries = byFunc.get(funcIdx);
  if (!entries || entries.length === 0) {
    return null;
  }
  let lo = 0;
  let hi = entries.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (entries[mid].offset <= offset) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo === 0) {
    return null;
  }
  return entries[lo - 1];
}

function annotateTrapWithLinemap(err, wasmBytes) {
  if (!wasmBytes || !err) {
    return;
  }
  const byFunc = parseVibeLinemap(wasmBytes);
  if (byFunc.size === 0) {
    return;
  }
  const files = parseVibeDbgfiles(wasmBytes);
  const layout = parseWasmFuncEntryStarts(wasmBytes);
  const toRel = (funcIdx, moduleOff) => {
    const bi = funcIdx - layout.nimported;
    if (bi < 0 || bi >= layout.starts.length) {
      return moduleOff;
    }
    const start = layout.starts[bi];
    if (moduleOff >= start) {
      return moduleOff - start;
    }
    return moduleOff;
  };
  const emit = (name, funcIdx, moduleOff) => {
    const offset = toRel(funcIdx, moduleOff);
    const hit = resolveLinemap(byFunc, funcIdx, offset);
    if (hit && hit.line > 0 && hit.fileId >= 0 && hit.fileId < files.length && files[hit.fileId]) {
      console.error(`  frame: ${name} (${files[hit.fileId]}:${hit.line})`);
    } else {
      console.error(`  frame: ${name}`);
    }
  };
  const stack = err.stack ? String(err.stack) : "";
  // Node 24: `at wasm://wasm/hash:wasm-function[N]:0xOFF` (module offset)
  // Named:   `at main (wasm://wasm/hash:wasm-function[N]:0xOFF)`
  const reNamed = /at ([^(\n]+) \(wasm:\/\/wasm\/[^:]+:wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)\)/g;
  const reBare = /at wasm:\/\/wasm\/[^:]+:wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)/g;
  let match;
  let any = false;
  while ((match = reNamed.exec(stack)) !== null) {
    any = true;
    emit(match[1].trim(), Number(match[2]), parseInt(match[3], 16));
  }
  if (!any) {
    while ((match = reBare.exec(stack)) !== null) {
      emit(`wasm-function[${match[1]}]`, Number(match[1]), parseInt(match[2], 16));
    }
  }
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

const POLICY_STAT_TOKEN_DOMAIN = Buffer.from("vibe:selfcompile-policy:stat-token:v1\0", "ascii");
const POLICY_TOKEN_HIGH_BIT = 1n << 60n;
const POLICY_TOKEN_LOW_MASK = POLICY_TOKEN_HIGH_BIT - 1n;
let policyStatTokenConfig = null;
let policyRawFsConfig = null;

// #2825 step 1 -- the not-granted stub (docs/internal/design/capability-host-contract.md).
//
// ADR-0088's 2026-09-15 amendment makes `perform?` an instantiate-time branch,
// so an emitted module declares the ungranted arm's host import whether or not
// the build granted it. A host then has to be able to WITHHOLD a capability:
// link something of the right type so the module instantiates, and trap if the
// program ever calls it.
//
// This runner could not express that. Its `vibe` import module is a Proxy
// whose `get` answers an unknown field with `() => 0n`, so deleting a method
// does not withhold the capability -- it makes the capability answer zero,
// which is the silent-wrong failure this repo's design policy ranks worst.
// Measured on 945d755 with `node scripts/host_capability_probe.mjs`: a strict
// host refuses all 18 of a stage2's `vibe.*` imports with a LinkError, this
// runner instantiates every one of them and answers 0.
//
// `VIBE_HOST_WITHHOLD=fs_read_file,http_request` withholds those fields. It is
// checked BEFORE the implemented-methods table on purpose: withholding a
// capability the host CAN provide is the whole point, and a switch that only
// worked for unimplemented names would test nothing. Names are the wasm import
// field (`fs_read_file`), not the capability label (`Fs::read_file`), because
// the field is what the module declares and what a host links against.
function parseWithheldCapabilities(spec) {
  const names = new Set();
  for (const raw of String(spec ?? "").split(",")) {
    const name = raw.trim();
    if (name !== "") names.add(name);
  }
  return names;
}

const withheldCapabilities = parseWithheldCapabilities(process.env.VIBE_HOST_WITHHOLD);

// The stub itself. It traps rather than answering, so a mistake anywhere else
// in the contract -- a grant the host forgot to clear, a lowering that picked
// the granted arm -- surfaces as a trap naming the capability instead of as a
// zero flowing into user data.
// #2832 item 4: the async host imports this runner does not implement.
//
// The `vibe` import object is a Proxy whose fallthrough answers an unknown
// field with `() => 0n` (see the withheld-capability note above for why that
// default exists and what it costs). For the ADR-0089 futures and streams that
// default is not a missing capability, it is a wrong answer. Measured on this
// tree, one source per row, each built with `vibe build` and run here:
//
//   while n < 5 { sum = sum + host_stream_next(s) }  -> prints `sum=0`, exit 0
//   for b in s { sum = sum + b }                     -> RuntimeError: unreachable
//   let mut b = ...; while 0 <= b { ... }            -> RuntimeError: unreachable
//
// The first row is the one that matters: a host stream that was never provided
// reads as five zero bytes and the program SUCCEEDS. The same source under
// runtime/viberun with VIBE_ASYNC_STREAMS reads the bytes the host supplied.
//
// `vibe.sleep` is the control that shows this is about the missing members and
// not about this lane: it IS implemented here, and works (76 ms baseline vs
// 381 ms for `sleep_blocking(300)`).
//
// So these names fail on CALL, with a message naming the import and where the
// lane that implements them is. Failing on call rather than on link is
// deliberate: a program that merely links one of these and never reaches it
// does not need the capability, and refusing to instantiate would be a
// different claim than the one measured here.
const UNIMPLEMENTED_ASYNC_IMPORT_NAMES = new Set([
  "host_future_get",
  "host_future_wait",
  "host_stream_read",
  "host_stream_close",
]);

// The named forms carry the component import name after `$`, fixed at compile
// time (`host_future_named` / `host_stream_named` require a string literal).
const UNIMPLEMENTED_ASYNC_IMPORT_PREFIXES = [
  "host_future_get$",
  "wit_future_get$",
  "host_stream_get$",
];

function isUnimplementedAsyncImport(name) {
  if (UNIMPLEMENTED_ASYNC_IMPORT_NAMES.has(name)) return true;
  return UNIMPLEMENTED_ASYNC_IMPORT_PREFIXES.some((prefix) => name.startsWith(prefix));
}

function unimplementedAsyncImportStub(name) {
  return () => {
    throw new Error(
      `vibe.${name} is not implemented by this runner. The ADR-0089 host futures ` +
        `and streams are served by runtime/viberun on the component lane, linked ` +
        `from VIBE_ASYNC_FUTURES / VIBE_ASYNC_STREAMS -- build a component and run ` +
        `it there, or drop the host future/stream call from this program. This ` +
        `used to answer 0, which read as real data (#2832).`,
    );
  };
}

// Every other `vibe.*` name this runner does not implement (the
// `stdin_provider_*` trio, the #1537 arm / wait-any / cancel band,
// `host_arg_push`, `wit_response*`). Answering such a call with 0 would read as
// real data (#3278), so it fails on call, naming the import; instantiation still succeeds, so a module
// that imports such a name but never calls it keeps running.
//
// The hint names the lane that does serve the import, read from the host
// contract's bands (docs/generated/host-runtime-contract.json, enforced by
// scripts/check_host_runtime_contract.py): the component adapter, viberun's
// core runner for the debug band, or none for a name no lane declares.
let hostRuntimeContractBands = null;

function hostRuntimeContractBand(name) {
  if (hostRuntimeContractBands === null) {
    try {
      const contract = JSON.parse(
        fs.readFileSync(path.join(__dirname, "..", "docs", "generated", "host-runtime-contract.json"), "utf8"),
      );
      hostRuntimeContractBands = {
        adapter: new Set(contract.componentAdapterOnly || []),
        adapterPrefixes: (contract.componentAdapterPatterns || []).map((p) => p.prefix),
        debug: new Set(contract.viberunDebugOnly || []),
      };
    } catch (_) {
      hostRuntimeContractBands = { adapter: new Set(), adapterPrefixes: [], debug: new Set() };
    }
  }
  const bands = hostRuntimeContractBands;
  if (bands.adapter.has(name) || bands.adapterPrefixes.some((prefix) => name.startsWith(prefix))) {
    return "adapter";
  }
  if (bands.debug.has(name)) return "debug";
  return "unknown";
}

function unimplementedImportStub(name) {
  const band = hostRuntimeContractBand(name);
  const hint =
    band === "adapter"
      ? `It is served by the component adapter; build a component and run it there, or drop the call.`
      : band === "debug"
        ? `It is a debug import served by viberun's core runner; run the program with viberun, or build without debug hooks.`
        : `No host lane declares it, so check the import name, or drop the call.`;
  return () => {
    throw new Error(
      `vibe.${name} is not implemented by this runner, so the call has no answer. ${hint}`,
    );
  };
}

function capabilityWithheldStub(name) {
  return () => {
    throw new Error(`vibe capability withheld: ${name}`);
  };
}

function importSectionContains(wasmBytes, needle) {
  let offset = 8;
  while (offset < wasmBytes.length) {
    const id = wasmBytes[offset++];
    let size = 0;
    let shift = 0;
    let byte;
    do {
      if (offset >= wasmBytes.length || shift > 35) throw new Error("malformed wasm section length");
      byte = wasmBytes[offset++];
      size += (byte & 0x7f) * (2 ** shift);
      shift += 7;
    } while ((byte & 0x80) !== 0);
    const end = offset + size;
    if (!Number.isSafeInteger(end) || end > wasmBytes.length) throw new Error("malformed wasm section bounds");
    if (id === 2) return wasmBytes.subarray(offset, end).includes(needle);
    offset = end;
  }
  return false;
}

function rejectPolicyWasiModuleImports(wasmBytes, config = policyRawFsConfig) {
  if (!config) return;
  // A matching UTF-8 import name must contain these literal prefix bytes in
  // the import section. Avoid compiling ordinary large compiler modules a
  // second time; any possible denied module still goes through the engine's
  // actual import table.
  if (!importSectionContains(wasmBytes, Buffer.from("wasi:", "utf8"))) return;
  // Node 24's V8 can corrupt later GC-module compilation when Module.imports()
  // and instantiation run in the same process. Inspect in a short-lived Node
  // process so policy still uses the engine's actual import table before this
  // process instantiates the original bytes.
  const inspection = cp.spawnSync(process.execPath, [...process.execArgv, "-e", `
    "use strict";
    const fs = require("node:fs");
    const module = new WebAssembly.Module(fs.readFileSync(0));
    process.stdout.write(JSON.stringify(WebAssembly.Module.imports(module)));
  `], {
    input: wasmBytes,
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 1024 * 1024,
    stdio: ["pipe", "pipe", "pipe"],
  });
  if (inspection.error || inspection.status !== 0 || inspection.signal) {
    throw new Error(`policy wasm import inspection failed: ${String(inspection.stderr || inspection.error?.message || inspection.signal).slice(-1000)}`);
  }
  let imports;
  try { imports = JSON.parse(inspection.stdout); } catch { throw new Error("policy wasm import inspection returned malformed output"); }
  const deniedModules = [...new Set(
    imports.map(item => item.module).filter(moduleName => moduleName.startsWith("wasi:")),
  )].sort();
  if (deniedModules.length > 0) {
    throw new Error(`policy raw module import denied: ${deniedModules.join(",")}`);
  }
}

function isContainedPath(root, candidate) {
  const rel = path.relative(root, candidate);
  return rel === "" || (rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel));
}

function configurePolicyStatToken(mode, root) {
  if (mode === null && root === null) return null;
  if (mode !== "content-v1" || typeof root !== "string" || !path.isAbsolute(root)) {
    throw new Error("policy stat-token requires content-v1 and an absolute root");
  }
  const lexicalRoot = path.resolve(root);
  const rootInfo = fs.lstatSync(lexicalRoot);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
    throw new Error("policy stat root must be a physical directory");
  }
  const physicalRoot = fs.realpathSync.native(lexicalRoot);
  if (physicalRoot !== lexicalRoot || fs.realpathSync.native(process.cwd()) !== physicalRoot) {
    throw new Error("policy stat root must equal the physical cwd");
  }
  return {
    mode,
    root: physicalRoot,
    tokens: new Map(),
    transcript: crypto.createHash("sha256").update("vibe:selfcompile-policy:stat-token-transcript:v1\0", "ascii"),
    calls: 0,
  };
}

function configurePolicyRawFs(root, writeRoot, statConfig) {
  if (root === null && writeRoot === null) return null;
  if (!statConfig || typeof root !== "string" || !path.isAbsolute(root) || typeof writeRoot !== "string" || !path.isAbsolute(writeRoot)) {
    throw new Error("policy raw Fs requires content-v1 policy mode and absolute read/write roots");
  }
  const physical = fs.realpathSync.native(path.resolve(root));
  if (physical !== statConfig.root) throw new Error("policy raw Fs root must equal policy stat root");
  const lexicalWriteRoot = path.resolve(writeRoot);
  if (!isContainedPath(physical, lexicalWriteRoot)) throw new Error("policy raw Fs write root escapes policy root");
  const writeInfo = fs.lstatSync(lexicalWriteRoot);
  if (!writeInfo.isDirectory() || writeInfo.isSymbolicLink() || fs.realpathSync.native(lexicalWriteRoot) !== lexicalWriteRoot) {
    throw new Error("policy raw Fs write root must be a physical directory");
  }
  return { root: physical, writeRoot: lexicalWriteRoot };
}

function authorizePolicyRawPath(filePath, write = false, config = policyRawFsConfig) {
  if (!config) return;
  const lexical = path.resolve(config.root, filePath);
  const requiredRoot = write ? config.writeRoot : config.root;
  if (!isContainedPath(requiredRoot, lexical)) {
    throw new Error(`policy raw Fs ${write ? "write" : "read"} escapes allowed root: ${filePath}`);
  }
  const rel = path.relative(config.root, lexical);
  let cursor = config.root;
  for (const part of rel === "" ? [] : rel.split(path.sep)) {
    cursor = path.join(cursor, part);
    let info;
    try { info = fs.lstatSync(cursor); } catch (error) {
      if (error.code === "ENOENT") break;
      throw error;
    }
    if (info.isSymbolicLink()) throw new Error(`policy raw Fs path has symlink component: ${filePath}`);
  }
}

function authorizePolicyRawImport(name, args, instanceRef, config = policyRawFsConfig) {
  if (!config) return;
  if (name === "sh" || name === "sh_lines" || name.startsWith("sh_capture") || name.startsWith("tcp_") || name.startsWith("http_") || name === "fs_chdir") {
    throw new Error(`policy raw import denied: ${name}`);
  }
  const readOne = new Set(["fs_read_file", "fs_read_bytes", "fs_read_dir", "fs_read_dir_nul", "fs_readdir", "fs_exists", "fs_stat_token", "fs_is_dir", "fs_is_file"]);
  const writeOne = new Set(["fs_write_file", "fs_publish_immutable_text", "fs_write_bytes", "fs_mkdir", "fs_mkdir_p", "fs_remove", "fs_remove_file", "fs_remove_tree", "fs_append", "fs_open_write"]);
  if (readOne.has(name)) authorizePolicyRawPath(decodeStringArg(instanceRef, args[0]), false, config);
  if (writeOne.has(name)) authorizePolicyRawPath(decodeStringArg(instanceRef, args[0]), true, config);
  if (name === "fs_rename" || name === "fs_copy") {
    authorizePolicyRawPath(decodeStringArg(instanceRef, args[0]), name === "fs_rename", config);
    authorizePolicyRawPath(decodeStringArg(instanceRef, args[1]), true, config);
  }
}

function statIdentity(info) {
  const ns = (name, fallback) =>
    typeof info[name] === "bigint" ? info[name] : BigInt(Math.round(Number(info[fallback]) * 1e6));
  return [
    String(info.dev),
    String(info.ino),
    String(info.size),
    String(ns("mtimeNs", "mtimeMs")),
    String(ns("ctimeNs", "ctimeMs")),
    String(info.mode),
  ].join(":");
}

function resolvePolicyStatTarget(filePath, config) {
  const lexical = path.resolve(config.root, filePath);
  if (!isContainedPath(config.root, lexical)) {
    throw new Error(`policy stat path escapes root: ${filePath}`);
  }
  const rel = path.relative(config.root, lexical);
  let cursor = config.root;
  for (const part of rel === "" ? [] : rel.split(path.sep)) {
    cursor = path.join(cursor, part);
    const info = fs.lstatSync(cursor, { bigint: true });
    if (info.isSymbolicLink()) {
      if (cursor === lexical) return { finalSymlink: true, path: lexical };
      throw new Error(`policy stat path has a symlink ancestor: ${filePath}`);
    }
  }
  const physical = fs.realpathSync.native(lexical);
  if (!isContainedPath(config.root, physical)) {
    throw new Error(`policy stat physical path escapes root: ${filePath}`);
  }
  return { finalSymlink: false, path: physical };
}

function u64be(value) {
  const out = Buffer.alloc(8);
  out.writeBigUInt64BE(BigInt(value));
  return out;
}

function regularFilePayload(filePath, config) {
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  let fd;
  try {
    fd = fs.openSync(filePath, flags);
    const before = fs.fstatSync(fd, { bigint: true });
    if (!before.isFile()) throw new Error(`unsupported policy stat target: ${filePath}`);
    const payload = fs.readFileSync(fd);
    // Unit tests inject a synchronous mutation here to prove the pre/post
    // identity check; production configurations never carry this hook.
    if (typeof config?.testBeforeFinalFileStat === "function") {
      config.testBeforeFinalFileStat(filePath);
    }
    const after = fs.fstatSync(fd, { bigint: true });
    if (statIdentity(before) !== statIdentity(after) || BigInt(payload.length) !== after.size) {
      throw new Error(`unstable policy stat observation: ${filePath}`);
    }
    return payload;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function directoryPayload(dirPath) {
  const before = fs.statSync(dirPath, { bigint: true });
  if (!before.isDirectory()) throw new Error(`unsupported policy stat target: ${dirPath}`);
  const names = fs.readdirSync(dirPath, { encoding: "buffer" });
  names.sort(Buffer.compare);
  const chunks = [];
  for (const name of names) {
    if (name.includes(0)) throw new Error(`invalid directory entry under: ${dirPath}`);
    const decodedName = name.toString("utf8");
    if (!Buffer.from(decodedName, "utf8").equals(name)) {
      throw new Error(`non-UTF-8 directory entry under: ${dirPath}`);
    }
    const child = path.join(dirPath, decodedName);
    const info = fs.lstatSync(child, { bigint: true });
    let kind;
    if (info.isFile()) kind = 1;
    else if (info.isDirectory()) kind = 2;
    else if (info.isSymbolicLink()) kind = 3;
    else throw new Error(`unsupported directory entry under: ${dirPath}`);
    chunks.push(u64be(name.length), name, Buffer.from([kind]));
  }
  const after = fs.statSync(dirPath, { bigint: true });
  if (statIdentity(before) !== statIdentity(after)) {
    throw new Error(`unstable policy stat observation: ${dirPath}`);
  }
  return Buffer.concat(chunks);
}

function contentStatDigest(filePath, config) {
  const target = resolvePolicyStatTarget(filePath, config);
  if (target.finalSymlink) return { finalSymlink: true, digest: null };
  const info = fs.statSync(target.path, { bigint: true });
  let kind;
  let payload;
  if (info.isFile()) {
    kind = 1;
    payload = regularFilePayload(target.path, config);
  } else if (info.isDirectory()) {
    kind = 2;
    payload = directoryPayload(target.path);
  } else {
    throw new Error(`unsupported policy stat target: ${filePath}`);
  }
  const digest = crypto.createHash("sha256")
    .update(POLICY_STAT_TOKEN_DOMAIN)
    .update(Buffer.from([kind]))
    .update(u64be(payload.length))
    .update(payload)
    .digest();
  return { finalSymlink: false, digest };
}

function projectContentStatDigest(digest, config, projectedOverride = null) {
  const token = projectedOverride === null
    ? POLICY_TOKEN_HIGH_BIT | (digest.readBigUInt64BE(0) & POLICY_TOKEN_LOW_MASK)
    : BigInt(projectedOverride);
  if (token < POLICY_TOKEN_HIGH_BIT || token > (1n << 61n) - 1n) {
    throw new Error("invalid policy stat-token projection");
  }
  const key = token.toString();
  const full = digest.toString("hex");
  const prior = config.tokens.get(key);
  if (prior !== undefined && prior !== full) {
    throw new Error(`policy stat-token collision: ${key}`);
  }
  config.tokens.set(key, full);
  return token;
}

function recordContentStatDigest(config, channel, digest) {
  config.calls += 1;
  config.transcript.update(Buffer.from([channel])).update(digest);
}

function contentStatToken(filePath, config = policyStatTokenConfig, projectedOverride = null) {
  if (!config || config.mode !== "content-v1") throw new Error("policy stat-token is not configured");
  const result = contentStatDigest(filePath, config);
  if (result.finalSymlink) {
    recordContentStatDigest(config, 1, Buffer.alloc(32, 0xff));
    return -1n;
  }
  recordContentStatDigest(config, 1, result.digest);
  return projectContentStatDigest(result.digest, config, projectedOverride);
}

function policyStatAttestation(config = policyStatTokenConfig) {
  if (!config) return null;
  return {
    mode: config.mode,
    calls: config.calls,
    unique: config.tokens.size,
    transcript: config.transcript.copy().digest("hex"),
  };
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
  // 0.3 stream<u8> HTTP body; docs/internal/design/wasi-p3-async.md §3.3). Unset =>
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

// #3109: this runner never calls `process.exit()` on a path that has run
// guest code. On Node 24, `process.exit()` can hang forever: it shuts the V8
// platform down (NodePlatform::Shutdown joins the platform worker threads)
// while the isolate is still alive, and a concurrent Sparkplug job on one of
// those workers can be blocked in CollectionBarrier::AwaitCollectionBackground,
// waiting for a GC that only the exiting main thread could run. A NORMAL exit
// disposes the isolate first, which releases that worker, so every exit here
// sets `process.exitCode` and lets the event loop drain instead.
//
// The guest's `process_exit` import still has to stop the guest where it
// stands, so it throws a GuestExit out of the wasm call. The runner's catch
// paths recognise it and report its code rather than an error.
class GuestExit extends Error {
  constructor(code) {
    super(`guest requested exit ${code}`);
    this.name = "GuestExit";
    this.code = code;
  }
}
// The FIRST code the guest asked for, or null. `process.exit()` used to end
// the process on the spot, so that code is final: the 'exit' listener
// installed below re-applies it in case something (a guest `catch_all`, a
// later success path) ran after the throw and overwrote `process.exitCode`.
let guestExitCode = null;
function requestGuestExit(code) {
  if (guestExitCode === null) {
    guestExitCode = code;
  }
  process.exitCode = guestExitCode;
  throw new GuestExit(guestExitCode);
}
// Grace before the hard fallback in `exitAfterDrain`. A runner that has
// failed normally has nothing left to wait for, so the drain finishes long
// before this; the fallback exists only for a handle nobody closed.
const EXIT_DRAIN_GRACE_MS = 10000;
// End the process with `code` without `process.exit()`: record the code and
// return, so the event loop drains and Node takes its normal exit path. If a
// live handle (the daemon's stdin reader, say) would keep the loop open, the
// unref'd timer falls back to a hard exit after the grace period; it does not
// itself keep the process alive.
function exitAfterDrain(code) {
  process.exitCode = code;
  const fallback = setTimeout(() => process.exit(code), EXIT_DRAIN_GRACE_MS);
  fallback.unref();
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
// #2988: the export being run, so a host-level failure can say whether it hit
// the COMPILER (`cli_main`) or the user's program (`main` / `_start` / a test).
let currentInvokeGlobal = null;
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
      const e = perFn.get(fnName) ?? { total: 0, hit: 0, bits: [] };
      e.total += 1;
      e.hit += hit;
      e.bits.push(hit);
      perFn.set(fnName, e);
    }
    const branchPerFn = {};
    const branchGaps = [];
    for (const [fn, e] of perFn) {
      // #1556: `mask` gives each branch an identity that survives across
      // separately-linked entry programs. Global branch indices are per-program
      // and meaningless to compare, but the ORDINAL of a branch within its
      // owning function comes from lowering that function's body, so
      // (source-qualified fn name, ordinal) names the same source branch in
      // every entry that links the function. That pair is what lets the suite
      // report compute an exact branch UNION instead of only entry-weighted
      // sums. One char per branch ('1' taken / '0' not), ordinal-ascending.
      branchPerFn[fn] = { total: e.total, hit: e.hit, mask: e.bits.join("") };
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

// `label` (optional) is a phase name the guest attached to the mark (#1553);
// when present the line ends with ` name=<label>` so per-phase heap numbers
// can be grepped out of a compile's stderr. Unnamed marks (Profiler::now_us,
// plain VIBE_PROFILE_MEMORY_MARK env reads) keep the exact pre-#1553 format.
function emitProfileMemoryMark(label) {
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
  const nameSuffix = label ? ` name=${label}` : "";
  console.error(
    `[profile-memory] mark=${profileMemoryMarkIndex} pages=${memoryPages} bytes=${memoryBytes} heap_ptr=${heapPtr ?? "missing"} host_alloc_ptr=${hostAllocPtr} rss=${rss}${nameSuffix}`,
  );
  profileMemoryMarkIndex += 1;
}

const NAMED_MEMORY_MARK_ENV_PREFIX = "VIBE_PROFILE_MEMORY_MARK:";

function maybeEmitEnvMemoryMark(name) {
  if (name === "VIBE_PROFILE_MEMORY_MARK") {
    emitProfileMemoryMark();
  } else if (name.startsWith(NAMED_MEMORY_MARK_ENV_PREFIX)) {
    // #1553: named mark. The guest spells a phase name into the env-get key
    // (`Env::get("VIBE_PROFILE_MEMORY_MARK:<phase>")`); the env var itself is
    // never set, so the guest observes "" and the read is a pure signal.
    emitProfileMemoryMark(name.slice(NAMED_MEMORY_MARK_ENV_PREFIX.length));
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


  return {
    GuestExit,
    get HOST_IMPORT_ABI() { return HOST_IMPORT_ABI; },
    set HOST_IMPORT_ABI(value) { HOST_IMPORT_ABI = value; },
    OBJ_STRING,
    REQUESTED_HOST_IMPORT_ABI,
    TAG_INT,
    TAG_MASK,
    TAG_OBJ,
    WASM_PAGE_BYTES,
    annotateTrapWithLinemap,
    atomicWriteFileSync,
    authorizePolicyRawImport,
    authorizePolicyRawPath,
    buildFsMetadataHashParts,
    capabilityWithheldStub,
    configurePolicyRawFs,
    configurePolicyStatToken,
    contentStatDigest,
    contentStatToken,
    get covWasmBytesGlobal() { return covWasmBytesGlobal; },
    set covWasmBytesGlobal(value) { covWasmBytesGlobal = value; },
    cp,
    createPreview2CliStreamsHost,
    createPreview2FilesystemHost,
    currentGuestHeapBytes,
    get currentInvokeGlobal() { return currentInvokeGlobal; },
    set currentInvokeGlobal(value) { currentInvokeGlobal = value; },
    decodeHostBytes,
    decodeHostInt,
    decodeStringArg,
    decodeTaggedOrRawInt,
    detectHostImportAbi,
    dumpCoverage,
    encodeHostBool,
    encodeHostBytes,
    encodeHostInt,
    encodeHostString,
    encodeTaggedStringArray,
    exitAfterDrain,
    extractProfileRequest,
    findClosureEnv,
    fs,
    get guestExitCode() { return guestExitCode; },
    set guestExitCode(value) { guestExitCode = value; },
    get hostAllocPtrGlobal() { return hostAllocPtrGlobal; },
    set hostAllocPtrGlobal(value) { hostAllocPtrGlobal = value; },
    httpWorkerCall,
    get instanceRefGlobal() { return instanceRefGlobal; },
    set instanceRefGlobal(value) { instanceRefGlobal = value; },
    isPersistentArtifactCacheDisabled,
    isUnimplementedAsyncImport,
    maybeEmitEnvMemoryMark,
    parseArgs,
    parseExportFuncIndices,
    parseFuncToTableSlot,
    parseWasmMemoryLimitBytes,
    parseWithheldCapabilities,
    get passthroughArgsGlobal() { return passthroughArgsGlobal; },
    set passthroughArgsGlobal(value) { passthroughArgsGlobal = value; },
    path,
    get policyRawFsConfig() { return policyRawFsConfig; },
    set policyRawFsConfig(value) { policyRawFsConfig = value; },
    policyStatAttestation,
    get policyStatTokenConfig() { return policyStatTokenConfig; },
    set policyStatTokenConfig(value) { policyStatTokenConfig = value; },
    preGrowWasmMemory,
    profileNowUs,
    projectContentStatDigest,
    publishImmutableTextSync,
    readU32LE,
    readline,
    rejectPolicyWasiModuleImports,
    requestGuestExit,
    tcpWorkerCall,
    tryDecodeExceptionString,
    unimplementedAsyncImportStub,
    unimplementedImportStub,
    usage,
    withheldCapabilities,
    writeProfileRequest,
  };
}

module.exports = { createHostRuntime };
