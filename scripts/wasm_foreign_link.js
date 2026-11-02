"use strict";
// Linking for typed core-wasm imports (`import ./x.wasm { .. }`).
//
// The compiler turns such an import into core imports whose module is
// `vibe:wasm:<path>` (lib/@vibe/compiler/core/wasm_import_binding.vibe):
//
//   - one field per exported function, named exactly as the export;
//   - `vibe:memory.load8_u (i32) -> i32`, `vibe:memory.store8 (i32, i32)` and
//     `vibe:memory.size () -> i64` when the foreign module has a memory --
//     the foreign memory is not the vibe module's, so the host reads and
//     writes it on the program's behalf.
//
// `linkForeignWasmModules` instantiates each such module from `<path>`
// (relative to `VIBE_WASM_LINK_DIR`, default the working directory, which is
// where the compiler resolved the import) and returns the import namespaces.
// A foreign module that itself imports something is refused with the list of
// what it needs: nothing here satisfies another module's host imports, and
// answering them with stubs would run it wrong.

const fs = require("node:fs");
const path = require("node:path");

const FOREIGN_PREFIX = "vibe:wasm:";
const COMPONENT_PREFIX = "vibe:component:";

function foreignModuleNames(wasmModule) {
  const names = new Set();
  for (const imp of WebAssembly.Module.imports(wasmModule)) {
    if (imp.module.startsWith(FOREIGN_PREFIX)) names.add(imp.module);
  }
  return [...names];
}

function outOfBounds(name, addr, size) {
  return new WebAssembly.RuntimeError(
    `${name}: address ${addr} is outside the foreign memory (${size} bytes)`,
  );
}

async function linkForeignWasmModules(wasmModule, opts = {}) {
  const baseDir = opts.baseDir ?? process.env.VIBE_WASM_LINK_DIR ?? process.cwd();
  // A component import (`vibe:component:<path>`) needs the canonical ABI,
  // which viberun gets from wasmtime. Refuse it here: left to the runner's
  // fallback stub, every call would silently answer 0.
  const components = WebAssembly.Module.imports(wasmModule)
    .filter((i) => i.module.startsWith(COMPONENT_PREFIX))
    .map((i) => i.module);
  if (components.length > 0) {
    throw new Error(
      `cannot link '${components[0]}': importing a wasm component runs on viberun; the node runner cannot instantiate components`,
    );
  }
  const out = {};
  for (const name of foreignModuleNames(wasmModule)) {
    const rel = name.slice(FOREIGN_PREFIX.length);
    const file = path.isAbsolute(rel) ? rel : path.join(baseDir, rel);
    let bytes;
    try {
      bytes = fs.readFileSync(file);
    } catch (e) {
      throw new Error(`cannot link '${name}': ${e.message}`);
    }
    const mod = await WebAssembly.compile(bytes);
    const needs = WebAssembly.Module.imports(mod);
    if (needs.length > 0) {
      const shown = needs.slice(0, 8).map((i) => `${i.module}.${i.name} (${i.kind})`);
      throw new Error(
        `cannot link '${name}': it imports ${needs.length} item(s) and this runner provides none to a foreign module: ` +
          shown.join(", ") + (needs.length > 8 ? ", ..." : ""),
      );
    }
    const instance = await WebAssembly.instantiate(mod, {});
    if (typeof instance.exports._initialize === "function") {
      instance.exports._initialize();
    }
    const memory = Object.values(instance.exports).find((v) => v instanceof WebAssembly.Memory) ?? null;
    const ns = { ...instance.exports };
    if (memory) {
      ns["vibe:memory.load8_u"] = (addr) => {
        const a = addr >>> 0;
        const view = new Uint8Array(memory.buffer);
        if (a >= view.length) throw outOfBounds("vibe:memory.load8_u", a, view.length);
        return view[a];
      };
      ns["vibe:memory.store8"] = (addr, value) => {
        const a = addr >>> 0;
        const view = new Uint8Array(memory.buffer);
        if (a >= view.length) throw outOfBounds("vibe:memory.store8", a, view.length);
        view[a] = value & 0xff;
      };
      ns["vibe:memory.size"] = () => BigInt(memory.buffer.byteLength);
    }
    out[name] = ns;
  }
  return out;
}

module.exports = { COMPONENT_PREFIX, FOREIGN_PREFIX, foreignModuleNames, linkForeignWasmModules };
