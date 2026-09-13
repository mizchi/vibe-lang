#!/usr/bin/env node
// A bounded CI sample: four compiler-closure compiles per PR; two additional
// full CLI builds on main. All use one probe built from this checkout with an
// explicitly supplied stage2. No seed discovery or generation rebuild here.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const SCRIPT = fileURLToPath(import.meta.url);
const ROOT = dirname(dirname(SCRIPT));
const PROBE = "scripts/prelude_split_memory.vibex";
const CORPUS = "lib/@vibe/compiler/tests/codegen_lexer_test.vibe";
const CLI = "lib/@vibe/cli/entry.vibe";
const hash = value => createHash("sha256").update(value).digest("hex");
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const positive = value => Number.isSafeInteger(value) && value > 0;
const cacheHasData = dir => readdirSync(dir, { withFileTypes: true }).some(entry =>
  entry.isDirectory() ? cacheHasData(join(dir, entry.name)) : entry.isFile() && statSync(join(dir, entry.name)).size > 0);

function summarize(samples) {
  const first = samples[0];
  if (samples.some(s => s.wasm_sha256 !== first.wasm_sha256 || s.modules !== first.modules)) {
    throw new Error("output or split module count changed between rounds");
  }
  return {
    heap_delta_bytes: median(samples.map(s => s.heap_delta_bytes)),
    heap_ptr_bytes: median(samples.map(s => s.heap_ptr_bytes)),
    wall_ms_median: median(samples.map(s => s.wall_ms)),
    wasm_bytes: first.wasm_bytes,
    wasm_sha256: first.wasm_sha256,
    modules: first.modules,
    samples,
  };
}

export function collect({ root = ROOT, compiler, mode = "prelude", rounds = 1, run } = {}) {
  if (!Number.isSafeInteger(rounds) || rounds < 1) throw new Error("rounds must be a positive integer");
  if (!["prelude", "full"].includes(mode)) throw new Error("mode must be prelude or full");
  compiler = resolve(root, compiler);
  if (!statSync(compiler).size) throw new Error("compiler is empty");
  const started = performance.now();
  const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  const execute = run ?? ((args, options) => spawnSync("bash", [runner, ...args], options));
  mkdirSync(join(root, "_build"), { recursive: true });
  const work = mkdtempSync(join(root, "_build/selfhost-build-metrics."));
  const scratch = join(work, "scratch");
  const logs = join(work, "logs");
  mkdirSync(scratch);
  mkdirSync(logs);
  const probe = join(scratch, "probe.wasm");
  // Keep host setup (PATH, temp directories) but exclude ambient compiler,
  // instrumentation and Node selectors. Every measured process has this ABI.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("VIBE_") && !k.startsWith("NODE_")));
  Object.assign(env, {
    VIBE_PREOPEN_DIR: root, VIBE_LIB: join(root, "lib"),
    VIBE_IMPORT_ABI: "raw", VIBE_FS_COMPILE: "1", VIBE_BACKEND: "wasi",
    VIBE_RC: "0", VIBE_CHECKED_MODULE_CACHE: "off", VIBE_EXPERIMENTAL_AST_CACHE: "0",
    VIBE_WASM_MEMORY_STATS: "1",
  });
  function invoke(name, args, cache) {
    mkdirSync(cache, { recursive: true });
    const start = performance.now();
    const result = execute(args, { cwd: root, env: { ...env, VIBE_BUILD_CACHE_DIR: cache }, encoding: "utf8", timeout: 120_000, maxBuffer: 8 * 1024 * 1024 });
    const wall_ms = Math.max(1, Math.round(performance.now() - start));
    writeFileSync(join(logs, `${name}.log`), `${result.stdout ?? ""}${result.stderr ?? ""}`);
    if (result.error || result.status !== 0) throw new Error(`${name}: compile failed: ${result.error ?? result.stderr}; logs: ${logs}`);
    return { ...result, wall_ms };
  }
  try {
    invoke("probe-build", ["--invoke", "cli_main", compiler, PROBE, probe, "main"], join(scratch, "probe-cache"));
    if (!existsSync(probe) || !statSync(probe).size) throw new Error("probe build produced no output");
    const series = {
      whole: { cold: [], warm: [] }, split: { cold: [], warm: [] },
      selfhost: { cold: [], warm: [] },
    };
    for (let round = 1; round <= rounds; round++) {
      const lanes = round % 2 ? ["whole", "split"] : ["split", "whole"];
      if (mode === "full") lanes.push("selfhost");
      for (const seriesName of lanes) {
        const lane = seriesName === "split" ? "split" : "whole";
        const input = seriesName === "selfhost" ? CLI : CORPUS;
        const entry = seriesName === "selfhost" ? "cli_main" : "__no_entry__";
        const cache = join(scratch, `cache-${round}-${seriesName}`);
        let coldHash;
        for (const temperature of ["cold", "warm"]) {
          if (temperature === "warm" && !cacheHasData(cache)) throw new Error("cold compile did not populate the warm cache");
          const name = `${round}-${seriesName}-${temperature}`;
          const output = join(scratch, `${name}.wasm`);
          const result = invoke(name, ["--invoke", "_start", probe, input, entry, lane, output], cache);
          if (!existsSync(output) || !statSync(output).size) throw new Error(`${name}: missing output`);
          const rows = result.stdout.split("\n").filter(line => line.startsWith("prelude-split-memory "));
          const match = rows.length === 1 && rows[0].match(/^prelude-split-memory lane=(whole|split) modules=(\d+) heap_delta=(\d+) wasm_bytes=(\d+)$/);
          if (!match || match[1] !== lane || !positive(Number(match[3]))) throw new Error(`${name}: missing or invalid allocation reading`);
          const modules = Number(match[2]);
          if (!Number.isSafeInteger(modules) || (lane === "split" ? modules < 2 : modules !== 0)) throw new Error(`${name}: unexpected production split count`);
          const memory = result.stderr.split("\n").filter(line => line.startsWith("[wasm-memory] ")).at(-1);
          const heap = Number(memory?.match(/\bheap_ptr=(\d+)\b/)?.[1]);
          const pages = Number(memory?.match(/\bpages=(\d+)\b/)?.[1]);
          if (!positive(heap) || !positive(pages) || heap > pages * 65536) throw new Error(`${name}: invalid memory stats`);
          const bytes = readFileSync(output);
          if (bytes.length !== Number(match[4])) throw new Error(`${name}: output size disagrees with probe`);
          const wasm_sha256 = hash(bytes);
          if (temperature === "cold") coldHash = wasm_sha256;
          else if (wasm_sha256 !== coldHash) throw new Error(`${name}: output changed between cold and warm`);
          series[seriesName][temperature].push({ round, wall_ms: result.wall_ms, heap_delta_bytes: Number(match[3]), heap_ptr_bytes: heap, mem_pages: pages, modules, wasm_bytes: bytes.length, wasm_sha256 });
          rmSync(output);
        }
        rmSync(cache, { recursive: true });
      }
    }
    // Include the harness and runner in the measurement ABI. Compiler/source
    // changes are the subject of the series, so record their identity without
    // requiring it to match the main baseline.
    const protocol = [readFileSync(SCRIPT), ...[PROBE, "scripts/run_wasm_vibe_host_runner.sh", "scripts/wasm_vibe_host_runner.js"].map(p => readFileSync(join(root, p)))];
    return {
      schema: 1, protocol_sha256: hash(Buffer.concat(protocol)),
      compiler_sha256: hash(readFileSync(compiler)), probe_sha256: hash(readFileSync(probe)),
      node: process.version, platform: process.platform, arch: process.arch, rounds,
      cache: "fresh process per sample; empty directory for cold, same directory for warm; body and checked-module caches off",
      prelude: { input: CORPUS, entry: "__no_entry__", ...Object.fromEntries(["whole", "split"].map(lane => [lane, Object.fromEntries(["cold", "warm"].map(temp => [temp, summarize(series[lane][temp])]))])) },
      selfhost: mode === "full" ? { status: "ok", input: CLI, entry: "cli_main", cold: summarize(series.selfhost.cold), warm: summarize(series.selfhost.warm) } : { status: "main-only" },
      collection_wall_ms: Math.round(performance.now() - started),
    };
  } finally {
    // Keep small per-process logs, including failed compiles, for CI artifacts.
    // Large wasm/cache products never accumulate across rounds or CI runs.
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === SCRIPT) {
  const [compiler, output, mode = "prelude", rounds = "1"] = process.argv.slice(2);
  try {
    if (!compiler || !output || process.argv.length > 6) throw new Error("usage: selfhost_build_metrics.mjs <stage2.wasm> <out.json> [prelude|full] [rounds]");
    // Refuse stale success if this invocation fails before producing a snapshot.
    rmSync(output, { force: true });
    const result = collect({ compiler, mode, rounds: Number(rounds) });
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
    console.log(`[selfhost-build-metrics] ${output} (${result.collection_wall_ms} ms, ${result.rounds} round(s))`);
  } catch (error) {
    console.error(`[selfhost-build-metrics] ${error.message}`);
    process.exitCode = 1;
  }
}
