import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { collect, parseMemory, parsePeakRss } from "./compare_compiler_memory.mjs";

const wasm = Buffer.from("0061736d01000000", "hex");

function fixture(t, change = () => {}) {
  const root = mkdtempSync(join(tmpdir(), "compiler-memory-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, "scripts"));
  for (const name of ["run_wasm_vibe_host_runner.sh", "wasm_vibe_host_runner.js"]) writeFileSync(join(root, "scripts", name), "runner");
  writeFileSync(join(root, "baseline.wasm"), wasm);
  writeFileSync(join(root, "candidate-with-a-longer-name.wasm"), wasm);
  const calls = [];
  const run = (command, args, options) => {
    assert.equal(command, "/usr/bin/time");
    const rssPath = args[args.indexOf("-o") + 1];
    const [compiler, input, output, entry] = args.slice(args.indexOf("cli_main") + 1);
    const cache = options.env.VIBE_BUILD_CACHE_DIR;
    const warm = readdirSync(cache).length > 0;
    const call = { compiler, input, output, entry, cache, warm, env: options.env };
    calls.push(call);
    // Failures must not accidentally reuse the preceding sample's output.
    assert.equal(existsSync(output), false);
    writeFileSync(output, wasm);
    writeFileSync(join(cache, "entry"), "cached");
    writeFileSync(rssPath, process.platform === "darwin" ? "8192 maximum resident set size\n" : "peak_rss_kib=8\n");
    const result = { status: 0, stdout: "", stderr: "[wasm-memory] cli_main pages=2 bytes=131072 heap_ptr=4096 rss=8192\n" };
    change(call, result);
    return result;
  };
  const options = { root, baseline: "baseline.wasm", candidate: "candidate-with-a-longer-name.wasm", out: join(root, "result"), rounds: 4, run };
  return { options, calls };
}

test("comparison controls cache temperature, path lengths, order and target mode", t => {
  const { options, calls } = fixture(t);
  const ambient = { VIBE_BACKEND: "gc", VIBE_RC: "shadow", VIBE_NODE_EXTRA_FLAGS: "--cpu-prof", NODE_OPTIONS: "--no-warnings" };
  const prior = Object.fromEntries(Object.keys(ambient).map(k => [k, process.env[k]]));
  Object.assign(process.env, ambient);
  t.after(() => {
    for (const [k, value] of Object.entries(prior)) {
      if (value === undefined) delete process.env[k];
      else process.env[k] = value;
    }
  });
  const result = collect(options);
  assert.equal(calls.length, 16);
  assert.deepEqual(calls.filter(c => !c.warm).map(c => c.compiler.slice(-6)), ["a.wasm", "b.wasm", "b.wasm", "a.wasm", "a.wasm", "b.wasm", "b.wasm", "a.wasm"]);
  assert.equal(new Set(calls.map(c => c.compiler.length)).size, 1);
  assert.equal(new Set(calls.map(c => c.cache.length)).size, 1);
  assert.equal(new Set(calls.map(c => c.output)).size, 1);
  for (let i = 0; i < calls.length; i += 2) {
    assert.equal(calls[i].warm, false);
    assert.equal(calls[i + 1].warm, true);
    assert.equal(calls[i].cache, calls[i + 1].cache);
    assert.equal(calls[i].env.VIBE_RC, "1");
    assert.equal(calls[i].env.VIBE_BACKEND, "wasi");
    assert.equal(calls[i].env.VIBE_CODEGEN_BODY_CACHE, "off");
    assert.equal(calls[i].env.VIBE_NODE_EXTRA_FLAGS, undefined);
    assert.equal(calls[i].env.NODE_OPTIONS, undefined);
  }
  assert.equal(result.samples.length, 16);
  assert.equal(result.comparisons.length, 2);
  assert.equal(result.comparisons[0].heap_ptr_ratio, 1);
  assert.equal(result.samples[0].peak_rss_bytes, 8192);
  assert.equal(existsSync(join(options.out, "scratch")), false);
  assert.equal(JSON.parse(readFileSync(join(options.out, "summary.json"))).schema, 1);
});

test("full mode adds the CLI workload with its real entry", t => {
  const { options, calls } = fixture(t);
  collect({ ...options, rounds: 1, suite: "full" });
  assert.equal(calls.length, 8);
  assert.equal(calls[4].input, "lib/@vibe/cli/entry.vibe");
  assert.equal(calls[4].entry, "cli_main");
});

for (const [name, change, expected] of [
  ["different output", (c) => { if (c.compiler.endsWith("b.wasm")) writeFileSync(c.output, Buffer.concat([wasm, Buffer.from([0, 2, 1, 120])])); }, /output differs/],
  ["warm drift", (c) => { if (c.warm) writeFileSync(c.output, Buffer.concat([wasm, Buffer.from([0, 2, 1, 120])])); }, /output differs/],
  ["missing output", (c) => rmSync(c.output), /missing output/],
  ["invalid wasm", (c) => writeFileSync(c.output, "not wasm"), /invalid Wasm/],
  ["empty warm cache", (c) => rmSync(join(c.cache, "entry")), /populate/],
  ["failed process", (_c, r) => { r.status = 1; }, /process failed/],
  ["missing memory stats", (_c, r) => { r.stderr = ""; }, /memory stats/],
]) {
  test(`rejects ${name} without publishing success`, t => {
    const { options } = fixture(t, change);
    assert.throws(() => collect(options), expected);
    assert.equal(existsSync(join(options.out, "summary.json")), false);
    assert.equal(existsSync(join(options.out, "scratch")), false);
  });
}

test("does not overwrite an existing experiment", t => {
  const { options, calls } = fixture(t);
  mkdirSync(options.out);
  writeFileSync(join(options.out, "summary.json"), "prior");
  assert.throws(() => collect(options), /EEXIST/);
  assert.equal(calls.length, 0);
  assert.equal(readFileSync(join(options.out, "summary.json"), "utf8"), "prior");
});

test("memory units and unavailable metrics are explicit", () => {
  assert.equal(parsePeakRss("1024 maximum resident set size", "darwin"), 1024);
  assert.equal(parsePeakRss("peak_rss_kib=1024", "linux"), 1048576);
  assert.throws(() => parsePeakRss("", "linux"), /peak RSS/);
  assert.throws(() => parseMemory("[wasm-memory] run pages=1 bytes=65536 heap_ptr=70000 rss=100000"), /memory stats/);
  assert.throws(() => parseMemory("[wasm-memory] run pages=1 bytes=1 heap_ptr=1 rss=1"), /memory stats/);
});
