/// The probe decides what a host did with a withheld capability, so it is only
/// worth its output if it can tell the three outcomes apart. Each case here
/// builds a minimal module by hand rather than a compiled artifact, so a
/// failure is about the probe and not about whatever the compiler emitted that
/// day.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  CAPABILITY_IMPORT_MODULE,
  hostWithholding,
  probeLink,
  probeModule,
  unsynthesizableImports,
  withFallbackProxy,
} from "./host_capability_probe.mjs";

/// A module with one function type `(i64) -> (i64)` and the named function
/// imports, and nothing else. Section lengths are single-byte LEB128, which
/// holds while every section here stays under 128 bytes.
function moduleWithImports(imports) {
  const bytes = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
  bytes.push(0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e);
  const content = [imports.length];
  for (const [module, field, kind] of imports) {
    const m = [...Buffer.from(module, "utf8")];
    const f = [...Buffer.from(field, "utf8")];
    content.push(m.length, ...m, f.length, ...f);
    // kind 0x00 func (typeidx 0); 0x02 memory with `min` pages and no maximum.
    if (kind === "memory") content.push(0x02, 0x00, 2);
    else content.push(0x00, 0x00);
  }
  assert.ok(content.length < 128, "test module outgrew single-byte section lengths");
  bytes.push(0x02, content.length, ...content);
  return Uint8Array.from(bytes);
}

const ONE_CAPABILITY = [[CAPABILITY_IMPORT_MODULE, "fs_read_file"]];

test("a strict host that withholds the capability refuses to instantiate", () => {
  const mod = new WebAssembly.Module(moduleWithImports(ONE_CAPABILITY));
  const result = probeLink(mod, hostWithholding(mod, "fs_read_file"), "fs_read_file");
  assert.equal(result.outcome, "refused");
  assert.match(result.detail, /LinkError/);
});

test("the fallback-proxy host instantiates and the withheld capability answers", () => {
  const mod = new WebAssembly.Module(moduleWithImports(ONE_CAPABILITY));
  const host = withFallbackProxy(hostWithholding(mod, "fs_read_file"));
  const result = probeLink(mod, host, "fs_read_file");
  assert.equal(result.outcome, "silent");
  assert.match(result.detail, /answers 0/);
});

test("a trapping stub is reported as refused, not as an answer", () => {
  // The contract's not-granted stub. The probe is only useful if this reads
  // differently from the `() => 0n` above -- that difference IS the finding.
  const mod = new WebAssembly.Module(moduleWithImports(ONE_CAPABILITY));
  const host = hostWithholding(mod, "fs_read_file");
  host[CAPABILITY_IMPORT_MODULE].fs_read_file = () => {
    throw new Error("vibe capability withheld: Fs::read_file");
  };
  const result = probeLink(mod, host, "fs_read_file");
  assert.equal(result.outcome, "refused");
  assert.match(result.detail, /capability withheld: Fs::read_file/);
});

test("hostWithholding drops exactly the named field and keeps the rest", () => {
  const mod = new WebAssembly.Module(
    moduleWithImports([
      [CAPABILITY_IMPORT_MODULE, "fs_read_file"],
      [CAPABILITY_IMPORT_MODULE, "fs_exists"],
      ["wasi_snapshot_preview1", "fd_write"],
    ]),
  );
  const host = hostWithholding(mod, "fs_read_file");
  assert.equal(host[CAPABILITY_IMPORT_MODULE].fs_read_file, undefined);
  assert.equal(typeof host[CAPABILITY_IMPORT_MODULE].fs_exists, "function");
  assert.equal(typeof host.wasi_snapshot_preview1.fd_write, "function");
});

test("only the vibe import module is probed", () => {
  const report = probeModule(
    moduleWithImports([
      [CAPABILITY_IMPORT_MODULE, "fs_read_file"],
      ["wasi_snapshot_preview1", "fd_write"],
      ["wasi:cli/stdout@0.2.0", "get-stdout"],
    ]),
  );
  assert.deepEqual(report.capabilities, ["fs_read_file"]);
  assert.equal(report.imports.length, 3);
  assert.equal(report.rows.length, 1);
  assert.equal(report.rows[0].strict.outcome, "refused");
  assert.equal(report.rows[0].fallback_proxy.outcome, "silent");
});

test("a module with no vibe imports reports no capabilities", () => {
  const report = probeModule(moduleWithImports([["wasi_snapshot_preview1", "fd_write"]]));
  assert.deepEqual(report.capabilities, []);
  assert.deepEqual(report.rows, []);
});

test("a module importing something the probe cannot type is refused, not reported", () => {
  // The probe fabricates each import it satisfies, and `Module.imports` gives
  // it no TYPE to fabricate from. A guessed one-page memory fails to link for
  // a module wanting two, and every column would then read `refused` -- the
  // withheld capability blamed for the harness's own failure. Refusing to
  // report is the only honest answer available here.
  const bytes = moduleWithImports([
    [CAPABILITY_IMPORT_MODULE, "fs_read_file"],
    ["env", "memory", "memory"],
  ]);
  const mod = new WebAssembly.Module(bytes);
  assert.deepEqual(
    unsynthesizableImports(mod).map((e) => `${e.module}.${e.name}`),
    ["env.memory"],
  );
  assert.throws(() => probeModule(bytes), /also imports env\.memory \(memory\)/);
});

test("hostWithholding refuses rather than guessing a non-function import", () => {
  const mod = new WebAssembly.Module(
    moduleWithImports([
      [CAPABILITY_IMPORT_MODULE, "fs_read_file"],
      ["env", "memory", "memory"],
    ]),
  );
  assert.throws(() => hostWithholding(mod, "fs_read_file"), /cannot synthesize a memory import/);
});
