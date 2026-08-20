import {
  bindLspTransport,
  createLspBridge,
  createWebSocketTransport,
} from "./lsp.js";

// The committed distributable, which is the only vibe wasm this repository
// actually has. The previous default was
// "_build/wasm-gc/release/build/lib/lib.wasm" -- a MoonBit-host build output
// from `src/lib`, and NOTHING has produced that path since `src/` was retired
// in #594, so `createVibeService()` with no wasmPath always threw. The
// committed artifact exports every name ensureExportFunctions requires
// (memory, vibe_init, vibe_check, vibe_check_project, vibe_format,
// vibe_ide_outline, vibe_ide_peek_def, vibe_ide_search) and answers with real
// diagnostics.
//
// It is STALE: last built for #900, and it rejects `fn` declarations
// ("expected expr, got `fn`") while still typechecking `let`. Nothing in the
// tree rebuilds it -- see clients/wasm/README.md. Pass `wasmPath` or
// `wasmModule` when you have something newer.
const DEFAULT_WASM_PATH = "clients/wasm/vibe.wasm";
const DEFAULT_INPUT_PTR = 1024;
const DEFAULT_OUTPUT_PTR = 32768;
const DEFAULT_OUTPUT_CAP = 32768;

async function loadWasmSource(path) {
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
  return response;
}

async function instantiateWasm(source, imports) {
  if (
    typeof WebAssembly.Module !== "undefined" &&
    source instanceof WebAssembly.Module
  ) {
    const instance = await WebAssembly.instantiate(source, imports);
    return { instance };
  }
  if (typeof Response !== "undefined" && source instanceof Response) {
    if (typeof WebAssembly.instantiateStreaming === "function") {
      return await WebAssembly.instantiateStreaming(
        Promise.resolve(source),
        imports,
      );
    }
    const bytes = new Uint8Array(await source.arrayBuffer());
    const module = await WebAssembly.compile(bytes);
    const instance = await WebAssembly.instantiate(module, imports);
    return { instance };
  }
  const module = await WebAssembly.compile(source);
  const instance = await WebAssembly.instantiate(module, imports);
  return { instance };
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

function buildImportModule(moduleImpl, fallbackFn) {
  return new Proxy(moduleImpl, {
    get(target, key) {
      if (key in target) {
        return target[key];
      }
      return fallbackFn;
    },
  });
}

function normalizeCodePoint(value) {
  const code = Number(value);
  if (!Number.isFinite(code) || code < 0 || code > 0x10ffff) {
    return 0;
  }
  return Math.trunc(code);
}

function detectCurrentDir() {
  try {
    if (typeof Deno !== "undefined" && typeof Deno.cwd === "function") {
      return Deno.cwd();
    }
  } catch (_err) {
    // Fall through to process cwd or root.
  }
  if (typeof process !== "undefined" && typeof process.cwd === "function") {
    return process.cwd();
  }
  return "/";
}

function createMoonbitHostState() {
  return {
    env: new Map(),
    lastError: "",
    lastFileContent: new Uint8Array(),
    lastDirFiles: [],
  };
}

function createMoonbitFsImportModule(state) {
  function externString(value) {
    return { value: String(value) };
  }
  function externStringArray(values) {
    const list = Array.from(values);
    list.push("ffi_end_of_/string_array");
    return { values: list };
  }
  function externByteArray(bytes) {
    return { bytes: Uint8Array.from(bytes) };
  }
  function readExternString(externValue) {
    if (
      externValue &&
      typeof externValue === "object" &&
      typeof externValue.value === "string"
    ) {
      return externValue.value;
    }
    return "";
  }

  const impl = {
    begin_create_string() {
      return { chars: [] };
    },
    string_append_char(handle, ch) {
      if (!handle || !Array.isArray(handle.chars)) {
        return;
      }
      handle.chars.push(String.fromCodePoint(normalizeCodePoint(ch)));
    },
    finish_create_string(handle) {
      if (!handle || !Array.isArray(handle.chars)) {
        return externString("");
      }
      return externString(handle.chars.join(""));
    },
    begin_read_string(externValue) {
      return { value: readExternString(externValue), index: 0 };
    },
    string_read_char(handle) {
      if (!handle || typeof handle.value !== "string") {
        return -1;
      }
      if (handle.index >= handle.value.length) {
        return -1;
      }
      const code = handle.value.codePointAt(handle.index);
      if (code === undefined) {
        return -1;
      }
      handle.index += code > 0xffff ? 2 : 1;
      return code;
    },
    finish_read_string(_handle) {
      // no-op
    },
    begin_read_string_array(externValue) {
      if (
        externValue &&
        typeof externValue === "object" &&
        Array.isArray(externValue.values)
      ) {
        return { values: externValue.values, index: 0 };
      }
      return { values: ["ffi_end_of_/string_array"], index: 0 };
    },
    string_array_read_string(handle) {
      if (!handle || !Array.isArray(handle.values)) {
        return externString("ffi_end_of_/string_array");
      }
      if (handle.index >= handle.values.length) {
        return externString("ffi_end_of_/string_array");
      }
      const value = handle.values[handle.index];
      handle.index += 1;
      return externString(value);
    },
    finish_read_string_array(_handle) {
      // no-op
    },
    begin_create_byte_array() {
      return { bytes: [] };
    },
    byte_array_append_byte(handle, value) {
      if (!handle || !Array.isArray(handle.bytes)) {
        return;
      }
      handle.bytes.push(normalizeCodePoint(value) & 0xff);
    },
    finish_create_byte_array(handle) {
      if (!handle || !Array.isArray(handle.bytes)) {
        return externByteArray([]);
      }
      return externByteArray(handle.bytes);
    },
    begin_read_byte_array(externValue) {
      if (
        externValue &&
        typeof externValue === "object" &&
        externValue.bytes instanceof Uint8Array
      ) {
        return { bytes: externValue.bytes, index: 0 };
      }
      return { bytes: new Uint8Array(), index: 0 };
    },
    byte_array_read_byte(handle) {
      if (!handle || !(handle.bytes instanceof Uint8Array)) {
        return -1;
      }
      if (handle.index >= handle.bytes.length) {
        return -1;
      }
      const value = handle.bytes[handle.index];
      handle.index += 1;
      return value;
    },
    finish_read_byte_array(_handle) {
      // no-op
    },
    current_dir() {
      return externString(detectCurrentDir());
    },
    get_env_var(externKey) {
      const key = readExternString(externKey);
      return externString(state.env.get(key) ?? "");
    },
    get_env_var_exists(externKey) {
      const key = readExternString(externKey);
      return state.env.has(key);
    },
    get_env_vars() {
      const flat = [];
      for (const [key, value] of state.env.entries()) {
        flat.push(key, value);
      }
      return externStringArray(flat);
    },
    set_env_var(externKey, externValue) {
      state.env.set(readExternString(externKey), readExternString(externValue));
    },
    unset_env_var(externKey) {
      state.env.delete(readExternString(externKey));
    },
    args_get() {
      return externStringArray([]);
    },
    get_error_message() {
      return externString(state.lastError);
    },
    get_file_content() {
      return externByteArray(state.lastFileContent);
    },
    get_dir_files() {
      return externStringArray(state.lastDirFiles);
    },
    read_file_to_bytes_new(_path) {
      state.lastError = "unsupported in default JS host";
      state.lastFileContent = new Uint8Array();
      return -1;
    },
    write_bytes_to_file_new(_path, _content) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
    path_exists(_path) {
      return false;
    },
    create_dir_new(_path) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
    read_dir_new(_path) {
      state.lastError = "unsupported in default JS host";
      state.lastDirFiles = [];
      return -1;
    },
    is_file_new(_path) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
    is_dir_new(_path) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
    remove_file_new(_path) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
    remove_dir_new(_path) {
      state.lastError = "unsupported in default JS host";
      return -1;
    },
  };

  return buildImportModule(impl, () => 0);
}

function createMoonbitSysImportModule() {
  const impl = {
    is_windows() {
      return false;
    },
    exit(_code) {
      // no-op
    },
  };
  return buildImportModule(impl, () => 0);
}

function createSpectestImportModule() {
  const impl = {
    print_char(_ch) {
      // no-op
    },
  };
  return buildImportModule(impl, () => 0);
}

function buildDefaultImports() {
  const state = createMoonbitHostState();
  return {
    __moonbit_sys_unstable: createMoonbitSysImportModule(),
    __moonbit_fs_unstable: createMoonbitFsImportModule(state),
    __moonbit_time_unstable: buildImportModule({}, () => 0),
    spectest: createSpectestImportModule(),
  };
}

export async function createVibeService(options = {}) {
  const wasmPath = options.wasmPath ?? DEFAULT_WASM_PATH;
  const inputPtr = options.inputPtr ?? DEFAULT_INPUT_PTR;
  const outputPtr = options.outputPtr ?? DEFAULT_OUTPUT_PTR;
  const outputCap = options.outputCap ?? DEFAULT_OUTPUT_CAP;
  const imports = { ...buildDefaultImports(), ...options.imports };

  const wasmSource = options.wasmModule ?? await loadWasmSource(wasmPath);
  const { instance } = await instantiateWasm(wasmSource, imports);
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
