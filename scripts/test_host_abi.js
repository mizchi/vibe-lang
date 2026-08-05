#!/usr/bin/env node
// Host ABI contract snapshot test (docs/spec/host-abi.md).
//
// Compiles a pure program and an Fs-effect program with the real `vibe` launcher
// and asserts the import/export surface matches the documented host contract, so
// a change to what a host must provide can't land unnoticed:
//
//   - every artifact imports exactly `wasi_snapshot_preview1::fd_write` (+ the
//     `vibe::*` for the effects it uses) and nothing else,
//   - the artifact requires the exception-handling proposal (exports an `error`
//     tag),
//   - the Fs effect lowers to the `vibe::fs_*` host module (not wasip3, not
//     `__moonbit_*_unstable`).
//
// Needs a working launcher: VIBE_BIN=<path to vibe> node scripts/test_host_abi.js
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const VIBE = process.env.VIBE_BIN || "vibe";
const REPO = path.resolve(__dirname, "..");

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log(`ok: ${n}`)) : (fail++, console.error(`FAIL: ${n}${d ? " — " + d : ""}`)); };

// ---- minimal wasm section reader (imports + exports) ----------------------
function leb(b, p) { let r = 0, s = 0, x; do { x = b[p++]; r |= (x & 0x7f) << s; s += 7; } while (x & 0x80); return [r >>> 0, p]; }
function sections(file) {
  const b = fs.readFileSync(file);
  if (b.length < 8 || b.readUInt32LE(0) !== 0x6d736100) throw new Error("not a wasm module: " + file);
  const imports = [], exports = [];
  let p = 8;
  while (p < b.length) {
    const id = b[p++]; let n; [n, p] = leb(b, p); const end = p + n;
    if (id === 2) { // imports
      let c; [c, p] = leb(b, p);
      for (let i = 0; i < c; i++) {
        let l; [l, p] = leb(b, p); const mod = b.slice(p, p + l).toString(); p += l;
        [l, p] = leb(b, p); const fld = b.slice(p, p + l).toString(); p += l;
        const k = b[p++];
        if (k === 0) { [, p] = leb(b, p); }
        else if (k === 1) { p += 1; const f = b[p++]; if (f) [, p] = leb(b, p); [, p] = leb(b, p); }
        else if (k === 2) { const f = b[p++]; [, p] = leb(b, p); if (f) [, p] = leb(b, p); }
        else if (k === 3) { p += 2; }
        else if (k === 4) { p += 1; [, p] = leb(b, p); } // tag
        imports.push(`${mod}::${fld}`);
      }
    } else if (id === 7) { // exports
      let c; [c, p] = leb(b, p);
      for (let i = 0; i < c; i++) {
        let l; [l, p] = leb(b, p); const nm = b.slice(p, p + l).toString(); p += l;
        const k = b[p++]; let idx; [idx, p] = leb(b, p);
        exports.push({ name: nm, kind: k }); // kind 4 = tag (exceptions)
      }
    }
    p = end;
  }
  return { imports, exports };
}

function build(name, src) {
  const out = path.join(work, name + ".wasm");
  const file = path.join(work, name + ".vibe");
  fs.writeFileSync(file, src);
  const r = spawnSync(VIBE, ["build", file, "-o", out], { encoding: "utf8", timeout: 60000 });
  if (!fs.existsSync(out)) throw new Error(`build ${name} failed: ${r.stderr || r.stdout}`);
  return sections(out);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-abi-"));
process.on("exit", () => { try { fs.rmSync(work, { recursive: true, force: true }); } catch {} });

try {
  // --- Tier 0: pure / compute -------------------------------------------
  const pure = build("pure", "let add = (a: Int, b: Int) -> Int { a + b }\nlet main = () -> Int { add(2, 3) }\n");
  ok("pure: imports exactly { wasi_snapshot_preview1::fd_write }",
    JSON.stringify([...pure.imports].sort()) === JSON.stringify(["wasi_snapshot_preview1::fd_write"]),
    JSON.stringify(pure.imports));
  ok("pure: no vibe::* host imports (Tier 0 runs on any WASI p1 host)",
    !pure.imports.some((i) => i.startsWith("vibe::")));
  // #716/#733: exception machinery is emitted only when the program uses
  // exceptions (throw/handle/effects), so a pure program carries NO `error`
  // tag — Tier 0 now runs on hosts without the exceptions proposal.
  ok("pure: no `error` tag (Tier 0 needs no exceptions proposal)",
    !pure.exports.some((e) => e.name === "error" && e.kind === 4),
    JSON.stringify(pure.exports.map((e) => `${e.name}:${e.kind}`)));
  ok("pure: exports the WASI command entry `_start` + `memory`",
    pure.exports.some((e) => e.name === "_start") && pure.exports.some((e) => e.name === "memory"));

  // --- Tier 1: Fs effect -------------------------------------------------
  // #897: @vibe/fs is a .vpkg contract package — importing fs.vibe directly
  // is rejected at the package boundary (#729), so import the package
  // directory (resolves index.vpkg).
  const fsPkg = path.join(REPO, "lib", "@vibe", "fs");
  // #812 enforces the imported effect row: `read_file` is `with Fs`, so
  // the caller must declare it (the Fs op still lowers to a direct host call).
  const fsw = build("fsprog",
    `import ${fsPkg} { read_file }\nlet main = () -> Unit with Fs { let _ = read_file("/tmp/x"); () }\n`);
  ok("fs: still imports wasi_snapshot_preview1::fd_write", fsw.imports.includes("wasi_snapshot_preview1::fd_write"));
  ok("fs: Fs effect lowers to the vibe::fs_* host module", fsw.imports.includes("vibe::fs_read_file"),
    JSON.stringify(fsw.imports));
  ok("fs: no wasip3 / wasi:* component imports on the linear path",
    !fsw.imports.some((i) => i.startsWith("wasi:")), JSON.stringify(fsw.imports));
  ok("fs: no __moonbit_*_unstable imports (those are compiler-only)",
    !fsw.imports.some((i) => i.startsWith("__moonbit_")), JSON.stringify(fsw.imports));
  console.log("  [host-abi] fs imports:", JSON.stringify(fsw.imports));
} catch (e) {
  fail++; console.error("FAIL: " + e.message);
}

console.log(`\n[test_host_abi] ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
