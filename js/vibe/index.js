import {
  bindLspTransport,
  createLspBridge,
  createWebSocketTransport,
} from "./lsp.js";

const DEFAULT_WASM_PATH = "_build/wasm-gc/release/build/lib/lib.wasm";
const DEFAULT_INPUT_PTR = 1024;
const DEFAULT_OUTPUT_PTR = 32768;
const DEFAULT_OUTPUT_CAP = 32768;

async function loadWasmBytes(path) {
  if (typeof Deno !== "undefined" && typeof Deno.readFile === "function") {
    return await Deno.readFile(path);
  }
  if (typeof process !== "undefined" && process.versions?.node) {
    const fs = await import("node:fs/promises");
    return await fs.readFile(path);
  }
  const response = await fetch(path);
  if (!response.ok) {
    throw new Error(`failed to fetch wasm: ${path}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

function ensureExportFunctions(exports, wasmPath) {
  if (!exports.memory) {
    throw new Error(`missing export "memory" in ${wasmPath}`);
  }
  if (!exports.vibe_init) {
    throw new Error(`missing export "vibe_init" in ${wasmPath}`);
  }
  if (!exports.vibe_check) {
    throw new Error(`missing export "vibe_check" in ${wasmPath}`);
  }
  if (!exports.vibe_check_project) {
    throw new Error(`missing export "vibe_check_project" in ${wasmPath}`);
  }
  if (!exports.vibe_format) {
    throw new Error(`missing export "vibe_format" in ${wasmPath}`);
  }
  if (!exports.vibe_ide_outline) {
    throw new Error(`missing export "vibe_ide_outline" in ${wasmPath}`);
  }
  if (!exports.vibe_ide_peek_def) {
    throw new Error(`missing export "vibe_ide_peek_def" in ${wasmPath}`);
  }
  if (!exports.vibe_ide_search) {
    throw new Error(`missing export "vibe_ide_search" in ${wasmPath}`);
  }
}

function writeSource(memory, source, inputPtr, outputPtr) {
  const bytes = new TextEncoder().encode(source);
  if (bytes.length + inputPtr >= outputPtr) {
    throw new Error(`source too large: ${bytes.length}`);
  }
  new Uint8Array(memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

function readOutput(memory, outLen, outputPtr, outputCap) {
  if (outLen < 0) {
    throw new Error("wasm api returned error");
  }
  if (outLen > outputCap) {
    throw new Error(`output too large: ${outLen}`);
  }
  const bytes = new Uint8Array(memory.buffer, outputPtr, outLen);
  return new TextDecoder().decode(bytes);
}

function toRequestJson(request) {
  if (typeof request === "string") {
    return request;
  }
  return JSON.stringify(request);
}

export async function createVibeService(options = {}) {
  const wasmPath = options.wasmPath ?? DEFAULT_WASM_PATH;
  const inputPtr = options.inputPtr ?? DEFAULT_INPUT_PTR;
  const outputPtr = options.outputPtr ?? DEFAULT_OUTPUT_PTR;
  const outputCap = options.outputCap ?? DEFAULT_OUTPUT_CAP;
  const imports = options.imports ?? {};

  const bytes = await loadWasmBytes(wasmPath);
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  const exports = instance.exports;
  ensureExportFunctions(exports, wasmPath);

  const memory = exports.memory;
  const wasmInit = exports.vibe_init;
  const wasmCheck = exports.vibe_check;
  const wasmCheckProject = exports.vibe_check_project;
  const wasmFormat = exports.vibe_format;
  const wasmIdeOutline = exports.vibe_ide_outline;
  const wasmIdePeekDef = exports.vibe_ide_peek_def;
  const wasmIdeSearch = exports.vibe_ide_search;

  async function rawInit(request) {
    const payload = toRequestJson(request);
    const sourceLen = writeSource(memory, payload, inputPtr, outputPtr);
    const outLen = wasmInit(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function init(request) {
    return JSON.parse(await rawInit(request));
  }

  async function rawCheck(source) {
    const sourceLen = writeSource(memory, source, inputPtr, outputPtr);
    const outLen = wasmCheck(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function rawFormat(source) {
    const sourceLen = writeSource(memory, source, inputPtr, outputPtr);
    const outLen = wasmFormat(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function rawCheckProject(request) {
    const payload = toRequestJson(request);
    const sourceLen = writeSource(memory, payload, inputPtr, outputPtr);
    const outLen = wasmCheckProject(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function rawIdeOutline(request) {
    const payload = toRequestJson(request);
    const sourceLen = writeSource(memory, payload, inputPtr, outputPtr);
    const outLen = wasmIdeOutline(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function rawIdePeekDef(request) {
    const payload = toRequestJson(request);
    const sourceLen = writeSource(memory, payload, inputPtr, outputPtr);
    const outLen = wasmIdePeekDef(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function rawIdeSearch(request) {
    const payload = toRequestJson(request);
    const sourceLen = writeSource(memory, payload, inputPtr, outputPtr);
    const outLen = wasmIdeSearch(inputPtr, sourceLen, outputPtr, outputCap);
    return readOutput(memory, outLen, outputPtr, outputCap);
  }

  async function check(source) {
    return JSON.parse(await rawCheck(source));
  }

  async function format(source) {
    return JSON.parse(await rawFormat(source));
  }

  async function ideOutline(request) {
    return JSON.parse(await rawIdeOutline(request));
  }

  async function idePeekDef(request) {
    return JSON.parse(await rawIdePeekDef(request));
  }

  async function ideSearch(request) {
    return JSON.parse(await rawIdeSearch(request));
  }

  async function checkProject(project) {
    if (!(project.entry in project.files)) {
      throw new Error(`entry not found in files: ${project.entry}`);
    }
    return JSON.parse(await rawCheckProject(project));
  }

  if (options.bootstrap) {
    const result = await init(options.bootstrap);
    if (result.ok !== true) {
      const detail = typeof result.error === "string"
        ? result.error
        : "unknown error";
      throw new Error(`vibe_init failed: ${detail}`);
    }
  }

  return {
    wasmPath,
    instance,
    memory,
    rawInit,
    init,
    rawCheck,
    rawCheckProject,
    rawFormat,
    rawIdeOutline,
    rawIdePeekDef,
    rawIdeSearch,
    check,
    format,
    ideOutline,
    idePeekDef,
    ideSearch,
    checkProject,
  };
}

export { bindLspTransport, createLspBridge, createWebSocketTransport };
