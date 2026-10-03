"use strict";

// #3278: a `vibe.*` import the node runner does not implement must fail on
// call with a message naming it. The runner's import object is a Proxy whose
// fallthrough used to answer `() => 0n`, so an adapter-only import such as
// `vibe.stdin_provider_open` returned 0 as if the host had answered.
//
// The guest below imports one such name, calls it, and prints nothing: under
// the old fallthrough it exits 0. The red test runs a copy of the runner with
// the fallthrough restored and asserts exactly that, so the refusal is pinned
// to the branch rather than to anything else about the module (#2248).

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const RUNNER = path.join(__dirname, "wasm_vibe_host_runner.js");
const RUNTIME = path.join(__dirname, "wasm_vibe_host_runtime.js");

function uleb(n) {
  const out = [];
  do {
    let b = n & 0x7f;
    n >>>= 7;
    if (n !== 0) b |= 0x80;
    out.push(b);
  } while (n !== 0);
  return out;
}

function section(id, body) {
  return [id, ...uleb(body.length), ...body];
}

function name(s) {
  const bytes = [...Buffer.from(s, "utf8")];
  return [...uleb(bytes.length), ...bytes];
}

// Imports `vibe.<importName> : () -> i64` and exports `_start : () -> ()`,
// which calls it and drops the result when `call` is set.
function guestModule(importName, call) {
  const types = section(1, [
    2,
    0x60, 0, 1, 0x7e, // () -> i64
    0x60, 0, 0, // () -> ()
  ]);
  const imports = section(2, [1, ...name("vibe"), ...name(importName), 0x00, 0]);
  const funcs = section(3, [1, 1]);
  const exportsSec = section(7, [1, ...name("_start"), 0x00, 1]);
  const body = call ? [0x10, 0, 0x1a] : [];
  const fn = [0, ...body, 0x0b];
  const code = section(10, [1, ...uleb(fn.length), ...fn]);
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...types, ...imports, ...funcs, ...exportsSec, ...code]);
}

function withGuest(importName, call, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-runner-unknown-"));
  try {
    const wasm = path.join(dir, "guest.wasm");
    fs.writeFileSync(wasm, guestModule(importName, call));
    return fn(dir, wasm);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function run(runner, wasm) {
  return spawnSync(process.execPath, ["--experimental-wasm-exnref", runner, "--invoke", "_start", wasm], {
    encoding: "utf8",
    env: { ...process.env, VIBE_IMPORT_ABI: "raw" },
    timeout: 60000,
  });
}

test("a call to an unimplemented vibe import fails and names it", () => {
  withGuest("stdin_provider_open", true, (_dir, wasm) => {
    const r = run(RUNNER, wasm);
    assert.equal(r.status, 1, r.stderr);
    assert.match(r.stderr, /vibe\.stdin_provider_open is not implemented by this runner/);
  });
});

test("importing an unimplemented name without calling it still runs", () => {
  withGuest("stdin_provider_open", false, (_dir, wasm) => {
    const r = run(RUNNER, wasm);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stderr, "");
  });
});

test("red: with the old fallthrough restored, the same call answers 0 and exits 0", () => {
  withGuest("stdin_provider_open", true, (dir, wasm) => {
    const source = fs.readFileSync(RUNNER, "utf8");
    const mutated = source.replace("return unimplementedImportStub(name);", "return () => 0n;");
    assert.notEqual(mutated, source, "the red mutation matched nothing: the fallthrough moved");
    const runner = path.join(dir, "wasm_vibe_host_runner.js");
    fs.writeFileSync(runner, mutated);
    fs.copyFileSync(RUNTIME, path.join(dir, "wasm_vibe_host_runtime.js"));
    const r = run(runner, wasm);
    assert.equal(r.status, 0, r.stderr);
  });
});
