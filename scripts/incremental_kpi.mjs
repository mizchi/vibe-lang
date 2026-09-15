#!/usr/bin/env node
// The incremental-build KPI: how much of a rebuild an UNCHANGED rebuild skips,
// at three project sizes.
//
//   node scripts/incremental_kpi.mjs <stage2.wasm> [out.json]
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
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const stage2 = process.argv[2] || process.env.VIBE_STAGE2_WASM;
if (!stage2 || !existsSync(stage2)) throw new Error("usage: incremental_kpi.mjs <stage2.wasm> [out.json]");
const outPath = resolve(root, process.argv[3] || "_build/incremental_kpi.json");

// Three sizes, each a committed root so the corpus cannot drift with unrelated
// edits, and each with a real ENTRY -- a `__no_entry__` root skips the
// capability const-fold and the late DCE, which is most of what a real build
// does after the checker (#2818).
const corpora = [
  { name: "small", input: "bench/incremental/edit_cycle/entry.vibe", entry: "main" },
  { name: "medium", input: "scripts/review_lint.vibex", entry: "main" },
  { name: "selfhost", input: "lib/@vibe/cli/entry.vibe", entry: "cli_main" },
];

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
    wasm_sha256: createHash("sha256").update(readFileSync(output)).digest("hex") };
}

const rows = [];
for (const corpus of corpora) {
  if (!existsSync(join(root, corpus.input))) throw new Error(`missing corpus: ${corpus.input}`);
  const cache = join(work, `cache-${corpus.name}`);
  mkdirSync(cache, { recursive: true });
  const cold = compile(corpus, cache, `${corpus.name}-cold`);
  const warm = compile(corpus, cache, `${corpus.name}-warm`);
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
    heap_ratio: cold.heap_ptr_bytes ? warm.heap_ptr_bytes / cold.heap_ptr_bytes : null,
    wall_ratio: cold.wall_ms ? warm.wall_ms / cold.wall_ms : null,
    cold, warm,
  });
  const r = rows.at(-1);
  console.log(`[incremental-kpi] ${corpus.name.padEnd(9)} modules=${String(planned).padStart(4)} `
    + `skipped=${(r.modules_skipped_ratio * 100).toFixed(0).padStart(3)}% `
    + `heap=${(r.heap_ratio * 100).toFixed(0).padStart(3)}% wall=${(r.wall_ratio * 100).toFixed(0).padStart(3)}%`);
}

const doc = {
  schema: "incremental_kpi", version: 1,
  created_at: new Date().toISOString(),
  stage2_sha256: createHash("sha256").update(readFileSync(stage2)).digest("hex"),
  selectors: Object.fromEntries(Object.entries(env).filter(([k]) => k.startsWith("VIBE_"))),
  deterministic: ["modules_planned", "modules_rechecked", "modules_reused", "parse_operations",
    "checker_executions", "heap_ptr_bytes"],
  advisory: ["wall_ms"],
  corpora: rows,
};
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(doc, null, 2) + "\n");
rmSync(work, { recursive: true, force: true });
console.log(`[incremental-kpi] wrote ${outPath}`);
