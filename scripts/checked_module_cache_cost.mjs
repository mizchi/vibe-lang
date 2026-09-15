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
// - Every sample must be seen to be what it is called. "warm" that reused
//   nothing is a second cold build, and the ratio then describes the machine
//   rather than the cache; "cold" that reused something was never cold. Both
//   are read from the compiler's own telemetry rather than inferred from the
//   timings, because a timing cannot tell the two apart -- which is #2825 §3
//   (a cache that replayed nothing while every published number looked healthy)
//   reproduced inside the tool built to catch it (#2836 §2).
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, totalmem } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { parseMemory, parsePeakRss } from "./compare_compiler_memory.mjs";
import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";
import { readModuleArtifacts } from "./cache_artifacts.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const stage2 = argv.find(a => !a.startsWith("--")) || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !existsSync(stage2)) throw new Error("pass a freshly built stage2.wasm, or set VIBE_STAGE2_WASM");
const flag = (name, fallback) => {
  const at = argv.indexOf(name);
  return at === -1 ? fallback : argv[at + 1];
};
const rounds = Number(flag("--rounds", "3"));
// The codegen body cache is the OTHER half of a warm build (#2388): it
// replays bodies this lane never touches. Held at "off" by default so the
// checked-module lane is measured alone, and varied to ask whether the two
// caches add up or overlap (#2507 phase 3).
const bodyCache = flag("--body-cache", "off");
if (!["off", "on", "verify"].includes(bodyCache)) throw new Error("--body-cache must be off, on or verify");
if (!Number.isSafeInteger(rounds) || rounds < 1) throw new Error("--rounds must be a positive integer");
const outDir = resolve(root, flag("--out", join("_build", "checked-module-cost")));
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const median = values => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

const allCases = [
  // The compiler's own closure through its CLI entry: 219 planned modules,
  // the workload every incremental claim in docs/incremental-build.md is
  // ultimately about.
  { name: "cli", input: "lib/@vibe/cli/entry.vibe", entry: "cli_main" },
  // A mid-size single-package closure, so a difference can be attributed to
  // scale rather than to one outlier program.
  { name: "closure", input: "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", entry: "__no_entry__" },
];
// `--cases closure` narrows the corpus. The reason it exists is the companion
// self-test: the assertions below have to be shown to FAIL, once per mutation,
// and the `cli` closure costs ~20s a compile (#2248 -- a gate is worth nothing
// until it has been made to fail, and a red test nobody can afford to run is
// not one). Nothing else passes it; a full run is still every case.
const selected = flag("--cases", "");
const cases = selected ? selected.split(",").map(name => {
  const corpus = allCases.find(entry => entry.name === name);
  if (!corpus) throw new Error(`--cases: no such case ${JSON.stringify(name)} (have ${allCases.map(c => c.name).join(", ")})`);
  return corpus;
}) : allCases;
const lanes = ["off", "on"];

// What each lane must be SEEN to do before a sample from it is accepted.
//
// `off` is not an empty control: it is the conservative fingerprint plus
// TDRE9, today's default reuse and exactly what promoting this cache has to
// beat. So a warm `off` run that reused nothing disqualifies its sample just
// as a warm `on` run that replayed no artifact does -- in both cases the pair
// being compared is cold against cold.
const laneContract = {
  off: { schema: 4, class: "conservative fingerprint + dependency transport env",
    reused: t => t.modules_reused_conservative_fingerprint + t.modules_reused_dependency_transport_env },
  on: { schema: 5, class: "checked-module artifact",
    reused: t => t.modules_reused_checked_module_artifact },
};

const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("VIBE_") && !k.startsWith("NODE_")));
Object.assign(env, {
  PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ""}`,
  VIBE_PREOPEN_DIR: root, VIBE_LIB: join(root, "lib"), VIBE_IMPORT_ABI: "raw",
  VIBE_FS_COMPILE: "1", VIBE_BACKEND: "wasi", VIBE_RC: "1",
  // Held fixed: the per-file AST cache stands down under this cache (see
  // docs/checked-body-transport.md), so leaving it on would measure that
  // interaction instead of this lane.
  VIBE_EXPERIMENTAL_AST_CACHE: "0", VIBE_CODEGEN_BODY_CACHE: bodyCache,
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
        const telemetryFile = join(scratch, `${name}.telemetry.json`);
        rmSync(telemetryFile, { force: true });
        const timeArgs = process.platform === "darwin" ? ["-l", "-o", rssFile] : ["-f", "peak_rss_kib=%M", "-o", rssFile];
        const command = ["bash", runner, "--invoke", "cli_main", resolve(stage2), corpus.input, output, corpus.entry];
        const start = performance.now();
        const result = spawnSync(timeBinary ?? command[0],
          timeBinary ? [...timeArgs, ...command] : command.slice(1), {
          cwd: root, env: { ...env, VIBE_CHECKED_MODULE_CACHE: lane, VIBE_BUILD_CACHE_DIR: cache,
            VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryFile },
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
        const contract = laneContract[lane];
        if (!existsSync(telemetryFile)) throw new Error(`${name}: the compile emitted no incremental telemetry`);
        const telemetry = parseIncrementalTelemetry(readFileSync(telemetryFile, "utf8"), telemetryFile);
        if (telemetry.schema !== contract.schema) {
          throw new Error(`${name}: telemetry schema ${telemetry.schema}, expected ${contract.schema} on the ${lane} lane`);
        }
        const reused = contract.reused(telemetry);
        const shape = JSON.stringify(telemetry);
        if (temperature === "cold") {
          // The directory was created empty a few lines up, so anything reused
          // here came from somewhere this protocol does not control.
          if (reused !== 0) throw new Error(`${name}: the cold run reused ${reused} module(s) (${contract.class}) from a cache directory this run created empty; it is not a cold sample: ${shape}`);
          if (lane === "on" && readModuleArtifacts(cache).length === 0) {
            throw new Error(`${name}: the cold run published no checked-module artifact, so nothing warm can consume one: ${shape}`);
          }
        } else if (reused === 0) {
          throw new Error(`${name}: the warm run reused nothing (${contract.class}), so this pair is cold against cold and its ratio is not about the cache: ${shape}`);
        }
        samples.push({ round, case: corpus.name, lane, temperature, wall_ms,
          heap_ptr_bytes: memory.heap_ptr_bytes, linear_memory_bytes: memory.linear_memory_bytes,
          peak_rss_bytes: timeBinary ? parsePeakRss(readFileSync(rssFile, "utf8"), process.platform) : null,
          modules_planned: telemetry.modules_planned, modules_rechecked: telemetry.modules_rechecked,
          modules_reused_in_lane_class: reused });
        console.log(`[checked-module-cost] ${name} wall=${(wall_ms / 1000).toFixed(2)}s heap=${(memory.heap_ptr_bytes / 1e6).toFixed(0)}MB reused=${reused}/${telemetry.modules_planned}`);
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
  stage2: resolve(stage2), stage2_sha256: hash(readFileSync(stage2)), rounds, body_cache: bodyCache,
  node: process.version, platform: process.platform, arch: process.arch,
  cpu: cpus()[0]?.model, host_memory_bytes: totalmem(),
  selectors: Object.fromEntries(Object.entries(env).filter(([k]) => k.startsWith("VIBE_"))),
  cache: "one isolated VIBE_BUILD_CACHE_DIR per (round, case, lane); cold then warm inside it; OS cache uncontrolled",
  reuse_evidence: Object.fromEntries(lanes.map(lane => [lane,
    `cold must reuse 0; warm must reuse >0 of class "${laneContract[lane].class}"` +
    (lane === "on" ? "; cold must also publish a checked-module artifact" : "")])),
  peak_rss: timeBinary ? `measured with ${timeBinary}` : "NOT MEASURED: no time(1) on this host; heap_ptr only",
  output_equivalence: Object.fromEntries(outputs), summary, samples };
writeFileSync(join(scratch, "report.json"), JSON.stringify(report, null, 2) + "\n");
console.log(`[checked-module-cost] report: ${join(scratch, "report.json")}`);
