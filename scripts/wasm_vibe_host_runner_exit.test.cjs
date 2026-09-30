"use strict";

// #3109: the runner must end the process through Node's NORMAL exit path.
//
// On Node 24, `process.exit()` can hang forever: it shuts the V8 platform down
// while the isolate is alive, and a concurrent Sparkplug job on a platform
// worker can be parked waiting for a GC only the exiting main thread could
// run (gdb: NodePlatform::Shutdown -> uv_thread_join on the main thread,
// ConcurrentBaselineCompiler::JobDispatcher::Run ->
// CollectionBarrier::AwaitCollectionBackground on the worker). The hang is
// timing-dependent (about 6 in 2,200 runs under parallel load in #3100), so
// these tests pin the STRUCTURE that rules it out -- no reachable
// `process.exit()` but the drain fallback -- and the statuses the guest and
// the error paths must still produce.

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const RUNNER = path.join(__dirname, "wasm_vibe_host_runner.js");

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

function sleb64(v) {
  const out = [];
  let more = true;
  let n = BigInt(v);
  while (more) {
    let b = Number(n & 0x7fn);
    n >>= 7n;
    if ((n === 0n && (b & 0x40) === 0) || (n === -1n && (b & 0x40) !== 0)) {
      more = false;
    } else {
      b |= 0x80;
    }
    out.push(b);
  }
  return out;
}

function section(id, body) {
  return [id, ...uleb(body.length), ...body];
}

function name(s) {
  const bytes = [...Buffer.from(s, "utf8")];
  return [...uleb(bytes.length), ...bytes];
}

// A module importing `vibe.process_exit : (i64) -> i64` and exporting one
// `() -> ()` function per entry of `bodies`, each given as raw code bytes.
function guestModule(bodies) {
  const names = Object.keys(bodies);
  const types = section(1, [
    2,
    0x60, 1, 0x7e, 1, 0x7e, // (i64) -> i64
    0x60, 0, 0, // () -> ()
  ]);
  const imports = section(2, [1, ...name("vibe"), ...name("process_exit"), 0x00, 0]);
  const funcs = section(3, [names.length, ...names.map(() => 1)]);
  const exportsBody = [names.length];
  names.forEach((n, i) => exportsBody.push(...name(n), 0x00, ...uleb(i + 1)));
  const exportsSec = section(7, exportsBody);
  const codeBody = [names.length];
  for (const n of names) {
    const fn = [0, ...bodies[n], 0x0b];
    codeBody.push(...uleb(fn.length), ...fn);
  }
  const code = section(10, codeBody);
  return Buffer.from([0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0, ...types, ...imports, ...funcs, ...exportsSec, ...code]);
}

// `process_exit(code)`, then `unreachable`: if the call returned instead of
// unwinding the guest, the run traps and exits 1 with a stack on stderr.
const exitThenTrap = (code) => [0x42, ...sleb64(code), 0x10, 0, 0x1a, 0x00];
const trapNow = [0x00];
const nothing = [];

function withGuest(bodies, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-runner-exit-"));
  try {
    const wasm = path.join(dir, "guest.wasm");
    fs.writeFileSync(wasm, guestModule(bodies));
    return fn(dir, wasm);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function run(args) {
  return spawnSync(process.execPath, ["--experimental-wasm-exnref", RUNNER, ...args], {
    encoding: "utf8",
    env: { ...process.env, VIBE_IMPORT_ABI: "raw" },
    timeout: 60000,
  });
}

test("a guest process_exit unwinds the guest and becomes the exit status", () => {
  withGuest({ _start: exitThenTrap(7) }, (_dir, wasm) => {
    const r = run(["--invoke", "_start", wasm]);
    assert.equal(r.signal, null);
    assert.equal(r.status, 7, r.stderr);
    assert.equal(r.stderr, "");
  });
});

test("a guest process_exit(0) exits 0 even though it unwinds by throwing", () => {
  withGuest({ _start: exitThenTrap(0) }, (_dir, wasm) => {
    const r = run(["--invoke", "_start", wasm]);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stderr, "");
  });
});

test("error exits keep status 1: a trap, and a missing export", () => {
  withGuest({ _start: trapNow }, (_dir, wasm) => {
    const trapped = run(["--invoke", "_start", wasm]);
    assert.equal(trapped.status, 1);
    assert.match(trapped.stderr, /unreachable/);
    const missing = run(["--invoke", "no_such_export", wasm]);
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /missing export: no_such_export/);
  });
});

test("an invoke batch reports a guest exit as that target's status and runs on", () => {
  withGuest({ __test_a: exitThenTrap(3), __test_b: nothing }, (dir, wasm) => {
    const out = path.join(dir, "batch");
    const r = run(["--invoke", "__test_a", "--invoke", "__test_b", "--invoke-batch-dir", out, wasm]);
    assert.equal(r.status, 1, r.stderr);
    assert.equal(fs.readFileSync(path.join(out, "1.rc"), "utf8"), "3\n");
    assert.equal(fs.readFileSync(path.join(out, "1.err"), "utf8"), "");
    assert.equal(fs.readFileSync(path.join(out, "2.rc"), "utf8"), "0\n");
  });
});

test("the runner has no process.exit() call but the drain fallback", () => {
  // Comments are stripped first: this file's reasoning names the call, and
  // the check must see only code.
  const code = (fs
    .readFileSync(path.join(__dirname, "wasm_vibe_host_runtime.js"), "utf8") + fs.readFileSync(RUNNER, "utf8"))
    .split("\n")
    .filter((line) => !/^\s*\/\//.test(line))
    .join("\n");
  const calls = code.match(/process\.exit\(/g) || [];
  assert.equal(calls.length, 1, "process.exit( must appear only in exitAfterDrain's fallback timer");
  assert.match(code, /setTimeout\(\(\) => process\.exit\(code\), EXIT_DRAIN_GRACE_MS\);\n\s*fallback\.unref\(\);/);
});
