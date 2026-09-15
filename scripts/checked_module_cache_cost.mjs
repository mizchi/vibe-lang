#!/usr/bin/env node
// What the checked-module cache COSTS and SAVES on a compiler-sized closure.
//
//   node scripts/checked_module_cache_cost.mjs <stage2.wasm> [--rounds N] [--out dir]
//
// #1959 makes default-on promotion conditional on "oracle parity and measured
// wall/heap benefit". The parity oracle answers the first half; this answers
// the second, and it is deliberately NOT a gate -- it reports numbers and
// refuses to invent them, it does not hold a budget.
//
// Protocol, and why each part is there (AGENTS.md, "A perf comparison must
// control the persistent cache"):
//
// - One isolated VIBE_BUILD_CACHE_DIR per (round, case, lane). The cache
//   namespace embeds a hash of the compiler SOURCES, so two lanes of the SAME
//   compiler share a namespace: without separate directories the first lane's
//   cold run silently warms the second, and the gap that opens is larger than
//   most real differences.
// - Cold and warm are reported separately and compared only like to like.
//   `off` warm is not an empty control: it is today's default reuse
//   (conservative fingerprint plus TDRE9), which is exactly what promoting
//   this cache would have to beat.
// - Lane order alternates by round so a drifting machine cannot favour one.
// - Medians over rounds, and every sample is kept in the report.
// - Both lanes must emit the same wasm. A cheaper lane that emits different
//   bytes has not been measured, it has been disqualified.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, totalmem } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { parseMemory, parsePeakRss } from "./compare_compiler_memory.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const stage2 = argv.find(a => !a.startsWith("--")) || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !existsSync(stage2)) throw new Error("pass a freshly built stage2.wasm, or set VIBE_STAGE2_WASM");
const flag = (name, fallback) => {
  const at = argv.indexOf(name);
  return at === -1 ? fallback : argv[at + 1];
};
const rounds = Number(flag("--rounds", "3"));
if (!Number.isSafeInteger(rounds) || rounds < 1) throw new Error("--rounds must be a positive integer");
const outDir = resolve(root, flag("--out", join("_build", "checked-module-cost")));
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const median = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

const cases = [
  // The compiler's own closure through its CLI entry: 219 planned modules,
  // the workload every incremental claim in docs/incremental-build.md is
  // ultimately about.
  { name: "cli", input: "lib/@vibe/cli/entry.vibe", entry: "cli_main" },
  // A mid-size single-package closure, so a difference can be attributed to
  // scale rather than to one outlier program.
  { name: "closure", input: "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", entry: "__no_entry__" },
];
const lanes = ["off", "on"];

const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("VIBE_") && !k.startsWith("NODE_")));
Object.assign(env, {
  PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ""}`,
  VIBE_PREOPEN_DIR: root, VIBE_LIB: join(root, "lib"), VIBE_IMPORT_ABI: "raw",
  VIBE_FS_COMPILE: "1", VIBE_BACKEND: "wasi", VIBE_RC: "1",
  // Held fixed: the per-file AST cache stands down under this cache (see
  // docs/checked-body-transport.md), so leaving it on would measure that
  // interaction instead of this lane.
  VIBE_EXPERIMENTAL_AST_CACHE: "0", VIBE_CODEGEN_BODY_CACHE: "off",
  VIBE_WASM_NAMES: "0", VIBE_WASM_MEMORY_STATS: "1",
});

// Peak RSS needs GNU/BSD `time`, which not every container has. The
// compiler-owned `heap_ptr` is the number the memory KPI is stated in and is
// always available, so a missing `time` reports a null rather than failing --
// and says so in the report, because a silently absent column reads as a
// measured zero.
const timeBinary = ["/usr/bin/time", "/bin/time"].find(candidate => {
  try { accessSync(candidate, constants.X_OK); return true; } catch { return false; }
});

mkdirSync(outDir, { recursive: true });
const scratch = mkdtempSync(join(outDir, "run-"));
const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");
const samples = [];
const outputs = new Map();

for (let round = 0; round < rounds; round++) {
  for (const corpus of cases) {
    for (const lane of round % 2 ? [...lanes].reverse() : lanes) {
      const cache = join(scratch, `cache-${round}-${corpus.name}-${lane}`);
      mkdirSync(cache);
      for (const temperature of ["cold", "warm"]) {
        const name = `${round}-${corpus.name}-${lane}-${temperature}`;
        const output = join(scratch, "out.wasm");
        rmSync(output, { force: true });
        rmSync(`${output}.diag`, { force: true });
        const rssFile = join(scratch, `${name}.time`);
        const timeArgs = process.platform === "darwin" ? ["-l", "-o", rssFile] : ["-f", "peak_rss_kib=%M", "-o", rssFile];
        const command = ["bash", runner, "--invoke", "cli_main", resolve(stage2), corpus.input, output, corpus.entry];
        const start = performance.now();
        const result = spawnSync(timeBinary ?? command[0],
          timeBinary ? [...timeArgs, ...command] : command.slice(1), {
          cwd: root, env: { ...env, VIBE_CHECKED_MODULE_CACHE: lane, VIBE_BUILD_CACHE_DIR: cache },
          encoding: "utf8", timeout: 900_000, maxBuffer: 64 * 1024 * 1024,
        });
        const wall_ms = performance.now() - start;
        if (result.status !== 0 || !existsSync(output)) {
          writeFileSync(join(scratch, `${name}.log`), `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
          throw new Error(`compile failed: ${name} (see ${scratch}/${name}.log)`);
        }
        const digest = hash(readFileSync(output));
        const previous = outputs.get(corpus.name);
        if (previous === undefined) outputs.set(corpus.name, digest);
        else if (previous !== digest) throw new Error(`${corpus.name}: ${lane}/${temperature} emitted different wasm than an earlier sample`);
        const memory = parseMemory(result.stderr ?? "");
        samples.push({ round, case: corpus.name, lane, temperature, wall_ms,
          heap_ptr_bytes: memory.heap_ptr_bytes, linear_memory_bytes: memory.linear_memory_bytes,
          peak_rss_bytes: timeBinary ? parsePeakRss(readFileSync(rssFile, "utf8"), process.platform) : null });
        console.log(`[checked-module-cost] ${name} wall=${(wall_ms / 1000).toFixed(2)}s heap=${(memory.heap_ptr_bytes / 1e6).toFixed(0)}MB`);
      }
    }
  }
}

const summary = [];
for (const corpus of cases) {
  for (const temperature of ["cold", "warm"]) {
    const row = { case: corpus.name, temperature };
    for (const lane of lanes) {
      const picked = samples.filter(s => s.case === corpus.name && s.lane === lane && s.temperature === temperature);
      row[lane] = { wall_ms: median(picked.map(s => s.wall_ms)),
        heap_ptr_bytes: median(picked.map(s => s.heap_ptr_bytes)),
        peak_rss_bytes: timeBinary ? median(picked.map(s => s.peak_rss_bytes)) : null };
    }
    row.wall_ratio = row.on.wall_ms / row.off.wall_ms;
    row.heap_ratio = row.on.heap_ptr_bytes / row.off.heap_ptr_bytes;
    summary.push(row);
    console.log(`[checked-module-cost] ${corpus.name} ${temperature}: wall ${(row.off.wall_ms / 1000).toFixed(2)}s -> ${(row.on.wall_ms / 1000).toFixed(2)}s (${(row.wall_ratio * 100 - 100).toFixed(1)}%), heap ${(row.off.heap_ptr_bytes / 1e6).toFixed(0)}MB -> ${(row.on.heap_ptr_bytes / 1e6).toFixed(0)}MB (${(row.heap_ratio * 100 - 100).toFixed(1)}%)`);
  }
}

const report = { schema: "checked_module_cache_cost", version: 1, created_at: new Date().toISOString(),
  stage2: resolve(stage2), stage2_sha256: hash(readFileSync(stage2)), rounds,
  node: process.version, platform: process.platform, arch: process.arch,
  cpu: cpus()[0]?.model, host_memory_bytes: totalmem(),
  selectors: Object.fromEntries(Object.entries(env).filter(([k]) => k.startsWith("VIBE_"))),
  cache: "one isolated VIBE_BUILD_CACHE_DIR per (round, case, lane); cold then warm inside it; OS cache uncontrolled",
  peak_rss: timeBinary ? `measured with ${timeBinary}` : "NOT MEASURED: no time(1) on this host; heap_ptr only",
  output_equivalence: Object.fromEntries(outputs), summary, samples };
writeFileSync(join(scratch, "report.json"), JSON.stringify(report, null, 2) + "\n");
console.log(`[checked-module-cost] report: ${join(scratch, "report.json")}`);
