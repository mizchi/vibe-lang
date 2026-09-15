#!/usr/bin/env node
/// What a host does with a capability import it does not provide (#2825 step 1).
///
/// ADR-0088's 2026-09-15 amendment makes `perform?` an instantiate-time branch,
/// so the emitted module declares the ungranted arm's host import whether or
/// not the build granted it. Whether that is safe depends entirely on what a
/// host does with an import it withholds -- and the two runners in this repo
/// answer differently. This probe measures the answer on a real artifact
/// instead of reading it out of either implementation.
///
///   node scripts/host_capability_probe.mjs <module.wasm> [--json]
///
/// Exit 0 = the report was produced. Exit 1 = the module could not be probed
/// (not a wasm module, or it imports nothing from `vibe`). A module with no
/// `vibe.*` import cannot answer the question, so saying nothing about it is
/// the honest result, not a pass.

import { readFileSync } from "node:fs";

/// The import module the linear backend names for every capability
/// (`linked_compile.vibe`: `emit_name(import_content, "vibe")`). WASI and the
/// component-model interfaces are a separate surface with their own linking
/// rules, so they are listed but not probed.
export const CAPABILITY_IMPORT_MODULE = "vibe";

/// Imports this probe cannot satisfy, so it refuses to report on a module that
/// has any (Codex on #2844, P2).
///
/// `WebAssembly.Module.imports` returns module, name and kind -- and no TYPE.
/// So a memory, global or table import can only be fabricated by guessing:
/// `new WebAssembly.Memory({ initial: 1 })` for a module whose memory wants
/// more than one page, `0n` for a global that is mutable or not an i64, a
/// table with limits that are not the declared ones. Every guess that misses
/// makes instantiation fail, and the probe would then report `refused` for
/// BOTH host columns -- attributing to the withheld capability a refusal that
/// came from the harness. That is the same defect this whole contract is
/// about: a measurement reporting a number when it did not measure the thing.
///
/// Refusing costs nothing today: every artifact the linear backend emits
/// imports functions only (`linked_compile.vibe` emits `wasi_snapshot_preview1
/// fd_write` and the `vibe.*` capabilities, all funcs). If that changes, this
/// says so instead of quietly answering wrong.
export function unsynthesizableImports(mod) {
  return WebAssembly.Module.imports(mod).filter((entry) => entry.kind !== "function");
}

/// Build an import object that satisfies every import of `mod` EXCEPT the one
/// named -- a host that provides everything the program needs but withholds
/// this one capability. Callers must have rejected `unsynthesizableImports`
/// first; a non-function import here is a programming error, not a result.
export function hostWithholding(mod, withheldField) {
  const object = {};
  for (const entry of WebAssembly.Module.imports(mod)) {
    if (entry.kind !== "function") {
      throw new Error(`host_capability_probe: cannot synthesize a ${entry.kind} import (${entry.module}.${entry.name})`);
    }
    // The module object exists even when every field of it is withheld: a host
    // that withholds `Fs::read_file` still provides `vibe`. Creating it only
    // for the fields it keeps would make a one-capability module fail with
    // "module is not an object or function" -- a different refusal, from the
    // harness rather than from the withholding.
    const provided = (object[entry.module] ??= {});
    if (entry.module === CAPABILITY_IMPORT_MODULE && entry.name === withheldField) continue;
    provided[entry.name] = () => 0n;
  }
  return object;
}

/// The shape `scripts/wasm_vibe_host_runner.js` links with: `vibe` is a Proxy
/// whose `get` answers an unknown field with `() => 0n` rather than leaving it
/// absent (see its `const vibeModule = new Proxy(` handler).
export function withFallbackProxy(object) {
  const base = object[CAPABILITY_IMPORT_MODULE] ?? {};
  return {
    ...object,
    [CAPABILITY_IMPORT_MODULE]: new Proxy(base, {
      get(target, key) {
        return key in target ? target[key] : () => 0n;
      },
    }),
  };
}

/// Link `mod` against `imports` and report what the host did with `field`.
/// Returns `{ outcome, detail }` where outcome is one of:
///   "refused"  -- the module did not instantiate; the capability cannot be
///                 reached because the program cannot run at all
///   "silent"   -- the module instantiated and the withheld import resolved to
///                 something callable; the program runs and the call answers
///   "provided" -- the withheld import was resolvable after all (a host that
///                 does not actually withhold it)
export function probeLink(mod, imports, field) {
  let instance;
  try {
    instance = new WebAssembly.Instance(mod, imports);
  } catch (e) {
    return { outcome: "refused", detail: `${e.constructor.name}: ${e.message}` };
  }
  const resolved = imports[CAPABILITY_IMPORT_MODULE]?.[field];
  if (typeof resolved !== "function") {
    return { outcome: "silent", detail: "instantiated; withheld import resolved to a non-function" };
  }
  let answer;
  try {
    answer = String(resolved(0n));
  } catch (e) {
    return { outcome: "refused", detail: `instantiated, but the call trapped: ${e.message}` };
  }
  void instance;
  return { outcome: "silent", detail: `instantiated; the call answers ${answer}` };
}

export function probeModule(bytes) {
  const mod = new WebAssembly.Module(bytes);
  const imports = WebAssembly.Module.imports(mod);
  const unsynthesizable = unsynthesizableImports(mod);
  if (unsynthesizable.length > 0) {
    const named = unsynthesizable.map((e) => `${e.module}.${e.name} (${e.kind})`).join(", ");
    throw new Error(
      `this probe can only satisfy function imports, and this module also imports ${named}; ` +
        "a fabricated one of those can fail to link for its own reasons and would be reported as the capability being refused",
    );
  }
  const capabilities = imports
    .filter((entry) => entry.module === CAPABILITY_IMPORT_MODULE && entry.kind === "function")
    .map((entry) => entry.name);
  const rows = capabilities.map((field) => {
    const strict = hostWithholding(mod, field);
    return {
      field,
      strict: probeLink(mod, strict, field),
      fallback_proxy: probeLink(mod, withFallbackProxy(strict), field),
    };
  });
  return { imports, capabilities, rows };
}

function main(argv) {
  const json = argv.includes("--json");
  const path = argv.find((a) => !a.startsWith("--"));
  if (!path) {
    console.error("usage: node scripts/host_capability_probe.mjs <module.wasm> [--json]");
    return 1;
  }
  let report;
  try {
    report = probeModule(readFileSync(path));
  } catch (e) {
    console.error(`host_capability_probe: cannot probe ${path}: ${e.message}`);
    return 1;
  }
  if (report.capabilities.length === 0) {
    console.error(`host_capability_probe: ${path} imports nothing from "${CAPABILITY_IMPORT_MODULE}"; nothing to probe`);
    return 1;
  }
  if (json) {
    console.log(JSON.stringify(report, null, 2));
    return 0;
  }
  console.log(`# ${path}`);
  console.log(`# ${report.imports.length} import(s), ${report.capabilities.length} from "${CAPABILITY_IMPORT_MODULE}"`);
  console.log("withheld\tstrict-host\tfallback-proxy-host");
  for (const row of report.rows) {
    console.log(`${row.field}\t${row.strict.outcome}\t${row.fallback_proxy.outcome}`);
  }
  const first = report.rows[0];
  console.log(`#`);
  console.log(`# strict         (${first.field}): ${first.strict.detail}`);
  console.log(`# fallback proxy (${first.field}): ${first.fallback_proxy.detail}`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
