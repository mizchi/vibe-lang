#!/usr/bin/env node
// The incremental-build KPI: how much of a rebuild an UNCHANGED rebuild skips,
// at three project sizes.
//
//   node scripts/incremental_kpi.mjs <stage2.wasm> [out.json] [--corpora small,...]
//
// Why three sizes. Every incremental number this repository has published was
// measured on the compiler's own closure, and that closure is atypical twice
// over: 420 modules is far past what a user project has, and it is compiled
// through paths a small project never reaches. A KPI that only watches it
// cannot tell "incremental works" from "incremental works at 420 modules".
//
// What is trustworthy here. The telemetry counters and `heap_ptr` are
// DETERMINISTIC for a given input and cache state -- same compiler, same
// sources, same numbers -- so a change in them is a real change and N=1 is
// enough. Wall time on a shared CI runner is not; it is carried for
// orientation and must not be read as a regression on its own.
//
// The counters are also the part that fails LOUDLY when a cache quietly dies.
// #2818 is the case in point: the codegen body cache replayed nothing on every
// entry-point build for as long as it existed, and no published measurement
// showed it, because the only harness hardcoded the library-shaped entry. A
// KPI is worth having precisely where an absent number reads like a present
// one, so `modules_rechecked` is reported against `modules_planned` rather
// than alone.
//
// Reporting is not enough on its own, though, which is #2836 §2: a number
// nobody reads is not a check. So the two facts the ratios DEPEND on -- that
// the cold run was cold and the warm run reused something -- are asserted
// here, and a run that cannot show them fails instead of publishing a ratio
// about the machine. The levels are deliberately not asserted: how much gets
// skipped is the KPI, and a KPI with a budget is a gate.
//
// Body-cache publication is watched, not bounded. The telemetry has no counter
// for the codegen body cache at all, so each run also reports how many
// artifacts of each kind it left in the cache directory. Measured 2026-09-15:
// `checked_module` 0 everywhere (that cache is off on this lane) and
// `codegen_body_cache` small 0 / medium 1 / selfhost 0. Publication needs a
// replayable harvest (#2811), which linked_compile writes only under
// `pin_region_capacity >= 0 && !late_dce_rewrote_bodies`, so the two zeroes
// are #2825 §6 in view -- but WHICH of the two conditions each corpus misses
// is not established by these counts, and all three corpora have a real entry.
// Hence reported and not asserted: today's honest value is 0 on two of three,
// so a threshold would encode the open bug, and when §6 lands these zeroes
// become nonzero on the run that lands it.
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";
import { countArtifacts } from "./cache_artifacts.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const stage2 = process.argv[2] || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !existsSync(stage2)) throw new Error("usage: incremental_kpi.mjs <stage2.wasm> [out.json]");
const positional = process.argv.slice(3).filter((arg, at, all) =>
  !arg.startsWith("--") && all[at - 1] !== "--corpora");
const outPath = resolve(root, positional[0] || "_build/incremental_kpi.json");

// Three sizes, each a committed root so the corpus cannot drift with unrelated
// edits, and each with a real ENTRY -- a `__no_entry__` root skips the
// capability const-fold and the late DCE, which is most of what a real build
// does after the checker (#2818).
const allCorpora = [
  { name: "small", input: "bench/incremental/edit_cycle/entry.vibe", entry: "main" },
  { name: "medium", input: "scripts/review_lint.vibex", entry: "main" },
  { name: "selfhost", input: "lib/@vibe/cli/entry.vibe", entry: "cli_main" },
];
// `--corpora small` narrows the run, and exists for the companion self-test:
// the assertions above have to be shown to FAIL once per mutation, and the
// selfhost closure costs ~20s a compile (#2248 -- a red test nobody can afford
// to run is not one). A full run is still all three sizes.
const selected = process.argv.slice(2).includes("--corpora")
  ? process.argv[process.argv.indexOf("--corpora") + 1] : "";
const corpora = selected ? selected.split(",").map(name => {
  const corpus = allCorpora.find(entry => entry.name === name);
  if (!corpus) throw new Error(`--corpora: no such corpus ${JSON.stringify(name)} (have ${allCorpora.map(c => c.name).join(", ")})`);
  return corpus;
}) : allCorpora;

const work = mkdtempSync(join(root, "_build/incremental-kpi-"));
const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("VIBE_") && !k.startsWith("NODE_")));
Object.assign(env, {
  PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ""}`,
  VIBE_PREOPEN_DIR: root, VIBE_LIB: join(root, "lib"), VIBE_IMPORT_ABI: "raw",
  VIBE_FS_COMPILE: "1", VIBE_BACKEND: "wasi", VIBE_RC: "1",
  VIBE_WASM_MEMORY_STATS: "1",
  // The two caches this KPI is about, both at their production default except
  // the body cache, which is opt-in and is the one whose reuse went unwatched.
  VIBE_CODEGEN_BODY_CACHE: "on", VIBE_CHECKED_MODULE_CACHE: "off",
  VIBE_EXPERIMENTAL_AST_CACHE: "0",
});

function heapPtr(stderr) {
  const line = (stderr || "").split("\n").filter(l => l.startsWith("[wasm-memory] ")).at(-1) ?? "";
  const m = line.match(/\bheap_ptr=(\d+)\b/);
  return m ? Number(m[1]) : null;
}

function compile(corpus, cache, label) {
  const output = join(work, `${label}.wasm`);
  const telemetry = join(work, `${label}.json`);
  rmSync(output, { force: true });
  rmSync(telemetry, { force: true });
  const start = performance.now();
  const result = spawnSync("bash", [runner, "--invoke", "cli_main", resolve(stage2),
    corpus.input, output, corpus.entry], {
    cwd: root, env: { ...env, VIBE_BUILD_CACHE_DIR: cache, VIBE_INCREMENTAL_TELEMETRY_OUT: telemetry },
    encoding: "utf8", timeout: 900_000, maxBuffer: 64 * 1024 * 1024,
  });
  const wall_ms = performance.now() - start;
  if (result.status !== 0 || !existsSync(output)) {
    writeFileSync(join(work, `${label}.log`), `${result.stdout ?? ""}\n${result.stderr ?? ""}`);
    throw new Error(`${corpus.name}: compile failed (see ${work}/${label}.log)`);
  }
  if (!existsSync(telemetry)) throw new Error(`${corpus.name}: no incremental telemetry sidecar`);
  return { wall_ms, heap_ptr_bytes: heapPtr(result.stderr),
    telemetry: parseIncrementalTelemetry(readFileSync(telemetry, "utf8"), telemetry),
    cache_artifacts: countArtifacts(cache), // see "Body-cache publication" above
    wasm_sha256: createHash("sha256").update(readFileSync(output)).digest("hex") };
}

const rows = [];
for (const corpus of corpora) {
  if (!existsSync(join(root, corpus.input))) throw new Error(`missing corpus: ${corpus.input}`);
  const cache = join(work, `cache-${corpus.name}`);
  mkdirSync(cache, { recursive: true });
  const cold = compile(corpus, cache, `${corpus.name}-cold`);
  const warm = compile(corpus, cache, `${corpus.name}-warm`);
  // Every ratio below divides warm by cold, so both names have to be earned.
  // The directory was created empty a few lines up: anything the cold run
  // reused came from outside this protocol, and a warm run that reused nothing
  // is a second cold build whose ratio describes the machine, not the cache.
  if (cold.telemetry.modules_reused !== 0) {
    throw new Error(`${corpus.name}: the cold run reused ${cold.telemetry.modules_reused} module(s) from a cache directory this run created empty; it is not a cold baseline`);
  }
  if (warm.telemetry.modules_reused === 0) {
    throw new Error(`${corpus.name}: the warm rebuild reused nothing of ${warm.telemetry.modules_planned} planned module(s); there is no incremental build here to report a KPI for`);
  }
  // A warm rebuild of untouched sources must produce the same program. If it
  // does not, every ratio below is describing two different builds.
  if (cold.wasm_sha256 !== warm.wasm_sha256) {
    throw new Error(`${corpus.name}: warm rebuild changed the output — reuse is not observationally identical`);
  }
  const planned = warm.telemetry.modules_planned;
  rows.push({
    name: corpus.name, input: corpus.input, entry: corpus.entry, modules: planned,
    // The headline: the share of the module walk an unchanged rebuild skipped.
    // 1.0 is "nothing was rechecked", 0.0 is "a warm build is a cold build".
    modules_skipped_ratio: planned > 0 ? 1 - warm.telemetry.modules_rechecked / planned : null,
    cache_artifacts: { cold: cold.cache_artifacts, warm: warm.cache_artifacts },
    heap_ratio: cold.heap_ptr_bytes ? warm.heap_ptr_bytes / cold.heap_ptr_bytes : null,
    wall_ratio: cold.wall_ms ? warm.wall_ms / cold.wall_ms : null,
    cold, warm,
  });
  const r = rows.at(-1);
  console.log(`[incremental-kpi] ${corpus.name.padEnd(9)} modules=${String(planned).padStart(4)} `
    + `skipped=${(r.modules_skipped_ratio * 100).toFixed(0).padStart(3)}% `
    + `heap=${(r.heap_ratio * 100).toFixed(0).padStart(3)}% wall=${(r.wall_ratio * 100).toFixed(0).padStart(3)}% `
    + `body_cache_artifacts=${r.cache_artifacts.warm.codegen_body_cache}`);
}

const doc = {
  schema: "incremental_kpi", version: 1,
  created_at: new Date().toISOString(),
  stage2_sha256: createHash("sha256").update(readFileSync(stage2)).digest("hex"),
  selectors: Object.fromEntries(Object.entries(env).filter(([k]) => k.startsWith("VIBE_"))),
  deterministic: ["modules_planned", "modules_rechecked", "modules_reused", "parse_operations",
    "checker_executions", "heap_ptr_bytes", "cache_artifacts"],
  advisory: ["wall_ms"],
  asserted: "cold reuses 0 modules; warm reuses more than 0 (the levels are the KPI, not a budget)",
  corpora: rows,
};
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(doc, null, 2) + "\n");
rmSync(work, { recursive: true, force: true });
console.log(`[incremental-kpi] wrote ${outPath}`);
