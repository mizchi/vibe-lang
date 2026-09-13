import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { collect } from "./selfhost_build_metrics.mjs";

// The fake runner observes real cache directories and the requested source,
// so reversing a pair, sharing caches across lanes, or reusing an output fails.
function fixture(fn) {
  const root = mkdtempSync(join(tmpdir(), "selfhost-metrics-"));
  mkdirSync(join(root, "scripts"));
  for (const file of ["prelude_split_memory.vibex", "run_wasm_vibe_host_runner.sh", "wasm_vibe_host_runner.js"]) {
    writeFileSync(join(root, "scripts", file), file);
  }
  writeFileSync(join(root, "stage2.wasm"), "stage2");
  const calls = [];
  let fault = "";
  function run(args, options) {
    const [, invoke, compiler, input, ...rest] = args;
    const output = invoke === "cli_main" ? rest[0] : rest[2];
    assert.equal(existsSync(output), false, "each process must produce a fresh output");
    const cache = options.env.VIBE_BUILD_CACHE_DIR;
    const warm = existsSync(join(cache, "cached"));
    const lane = invoke === "cli_main" ? "probe" : rest[1];
    calls.push({ input, compiler, cache, warm, lane, env: options.env });
    if (fault === "empty-cache-directory") mkdirSync(join(cache, "directory"), { recursive: true });
    else if (fault !== "empty-cache") writeFileSync(join(cache, "cached"), fault === "empty-cache-file" ? "" : "frontend");
    if (fault === "exit") return { status: 1, stdout: "", stderr: "compile failed" };
    if (fault !== "missing-output") writeFileSync(output, lane + (warm && fault === "wrong-output" ? "wrong" : ""));
    const size = existsSync(output) ? readFileSync(output).length : 1;
    const allocated = warm ? 500 : 1000;
    return {
      status: 0,
      stdout: invoke === "cli_main" ? "" : `prelude-split-memory lane=${lane} modules=${lane === "split" && fault !== "fallback" ? 219 : 0} heap_delta=${fault === "zero" ? 0 : allocated} wasm_bytes=${size}\n`,
      stderr: fault === "missing-stats" ? "" : `[wasm-memory] run pages=1 bytes=65536 heap_ptr=2048 rss=4000\n`,
    };
  }
  const options = { root, compiler: join(root, "stage2.wasm"), rounds: 1, mode: "prelude", run };
  try { fn({ options, calls, setFault: value => { fault = value; } }); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

test("PR collection builds one probe and measures exactly two isolated cold/warm pairs", () => fixture(({ options, calls }) => {
  const result = collect(options);
  assert.equal(calls.length, 5);
  assert.deepEqual(calls.map(c => c.warm), [false, false, true, false, true]);
  assert.equal(new Set(calls.map(c => c.cache)).size, 3);
  assert.equal(result.prelude.split.cold.heap_delta_bytes, 1000);
  assert.equal(result.prelude.split.warm.heap_delta_bytes, 500);
  assert.equal(result.prelude.split.warm.modules, 219);
  assert.equal(result.prelude.split.warm.samples.length, 1);
  assert.equal(result.selfhost.status, "main-only");
  assert.ok(result.collection_wall_ms >= 0);
  assert.match(result.protocol_sha256, /^[a-f0-9]{64}$/);
}));

test("full collection also rebuilds the CLI with a separate cold/warm cache", () => fixture(({ options, calls }) => {
  const result = collect({ ...options, mode: "full" });
  assert.equal(calls.length, 7);
  assert.equal(new Set(calls.map(c => c.cache)).size, 4);
  assert.equal(result.selfhost.input, "lib/@vibe/cli/entry.vibe");
  assert.equal(result.selfhost.entry, "cli_main");
  assert.equal(result.selfhost.status, "ok");
  assert.equal(result.selfhost.cold.heap_ptr_bytes, 2048);
  assert.equal(result.selfhost.cold.wasm_sha256, result.selfhost.warm.wasm_sha256);
  assert.equal(calls.at(-1).input, result.selfhost.input);
}));

test("rounds alternate lane order without inheriting a previous round's cache", () => fixture(({ options, calls }) => {
  const result = collect({ ...options, rounds: 3 });
  assert.equal(calls.length, 13);
  assert.deepEqual(calls.filter(c => !c.warm).map(c => c.lane), ["probe", "whole", "split", "split", "whole", "whole", "split"]);
  assert.equal(new Set(calls.map(c => c.cache)).size, 7);
  assert.equal(result.prelude.whole.cold.samples.length, 3);
}));

test("ambient compiler selectors cannot change the measured protocol", () => fixture(({ options, calls }) => {
  const prev = process.env.VIBE_BACKEND;
  process.env.VIBE_BACKEND = "gc";
  try { collect(options); } finally {
    if (prev === undefined) delete process.env.VIBE_BACKEND;
    else process.env.VIBE_BACKEND = prev;
  }
  for (const { env } of calls) {
    assert.equal(env.VIBE_BACKEND, "wasi");
    assert.equal(env.VIBE_CHECKED_MODULE_CACHE, "off");
    assert.equal(env.VIBE_EXPERIMENTAL_AST_CACHE, "0");
    assert.equal(env.NODE_OPTIONS, undefined);
  }
}));

for (const [fault, message] of [
  ["exit", /compile failed/], ["missing-output", /output/],
  ["missing-stats", /memory/], ["zero", /allocation/],
  ["fallback", /split/], ["wrong-output", /output changed/],
  ["empty-cache", /cache/],
  ["empty-cache-directory", /cache/], ["empty-cache-file", /cache/],
]) {
  test(`refuses ${fault} instead of publishing a successful snapshot`, () => fixture(({ options, setFault }) => {
    setFault(fault);
    assert.throws(() => collect(options), message);
  }));
}

test("invalid sampling configuration is refused before running a compiler", () => fixture(({ options, calls }) => {
  for (const rounds of [0, -1, 1.5, NaN]) assert.throws(() => collect({ ...options, rounds }), /rounds/);
  assert.throws(() => collect({ ...options, mode: "typo" }), /mode/);
  assert.equal(calls.length, 0);
}));
