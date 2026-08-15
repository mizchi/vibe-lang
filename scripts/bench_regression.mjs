#!/usr/bin/env node
// Benchmark regression gate. Runs the fixtures in bench/regression/ via
// `vibe bench` and compares against a committed baseline.
//
// The gate is on bytes/op, which is DETERMINISTIC on the linear backend (a bump
// allocator allocates exactly the same bytes for the same input), so an
// allocation regression is caught reliably with zero flakiness. Wall-time is
// inherently noisy across machines/CI, so ns/op is reported as ADVISORY only and
// never fails the gate.
//
// Usage:
//   VIBE_BIN=<vibe> node scripts/bench_regression.mjs           # check
//   VIBE_BIN=<vibe> node scripts/bench_regression.mjs --update   # rewrite baseline
//
// Fixtures run concurrently (real OS-process parallelism via child_process,
// not vibe's own cooperative TaskGroup -- see docs/compiler-parallelism.md's
// "Shared-everything migration note" for why the latter can't help here
// today). Safe because each fixture is its own file with its own
// content-addressed compile-cache key and its own mktemp'd output files --
// no shared mutable state between concurrent `vibe bench` invocations.
//
// baseline.json shape: { "<file.vibe>": { "bytes_per_op": <int>, "ns_p50": <int> } }
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIR = join(ROOT, "bench", "regression");
const BASELINE = join(DIR, "baseline.json");
const VIBE = process.env.VIBE_BIN || "vibe";
const ITERS = process.env.BENCH_ITERS || "300";
const update = process.argv.includes("--update");

// The fixture set the gate covers (must run cleanly on the linear backend).
const FIXTURES = ["pure_bench.vibe", "alloc_bench.vibe", "lexer_keyword_bench.vibe", "lexer_string_bench.vibe", "parser_empty_metadata_bench.vibe", "parser_query_bench.vibe"];

function runBench(file) {
  return new Promise((resolve, reject) => {
    const child = spawn(VIBE, ["bench", join(DIR, file), "--iters", ITERS], { timeout: 120000 });
    let out = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { out += d; });
    child.on("error", reject);
    child.on("close", () => {
      const m = /vibe::bench .*?bytes_per_op=(\d+)/.exec(out);
      const t = /vibe::bench .*?ns_p50=(\d+)/.exec(out);
      if (!m) { reject(new Error(`bench ${file} produced no parseable result:\n${out}`)); return; }
      resolve({ bytes_per_op: +m[1], ns_p50: t ? +t[1] : null });
    });
  });
}

const resultList = await Promise.all(FIXTURES.map(runBench));
const results = Object.fromEntries(FIXTURES.map((f, i) => [f, resultList[i]]));

if (update) {
  writeFileSync(BASELINE, JSON.stringify(results, null, 2) + "\n");
  console.log(`[bench-regression] wrote baseline for ${FIXTURES.length} fixtures -> ${BASELINE}`);
  for (const f of FIXTURES) console.log(`  ${f}: ${results[f].bytes_per_op} B/op, p50 ${results[f].ns_p50} ns`);
  process.exit(0);
}

if (!existsSync(BASELINE)) {
  console.error(`[bench-regression] no baseline at ${BASELINE}; run with --update first`);
  process.exit(2);
}
const baseline = JSON.parse(readFileSync(BASELINE, "utf8"));

let failed = 0;
console.log("[bench-regression] bytes/op gate (deterministic); time is advisory\n");
for (const f of FIXTURES) {
  const cur = results[f];
  const base = baseline[f];
  if (!base) {
    console.log(`  ⚠️  ${f}: no baseline entry (run --update); current ${cur.bytes_per_op} B/op`);
    continue;
  }
  const dB = cur.bytes_per_op - base.bytes_per_op;
  // Advisory time delta.
  const tNote =
    base.ns_p50 && cur.ns_p50
      ? ` | time p50 ${cur.ns_p50}ns (${dPct(cur.ns_p50, base.ns_p50)} vs ${base.ns_p50}ns, advisory)`
      : "";
  if (dB > 0) {
    failed++;
    console.log(`  ❌ ${f}: bytes/op REGRESSED ${base.bytes_per_op} -> ${cur.bytes_per_op} (+${dB})${tNote}`);
  } else if (dB < 0) {
    console.log(`  ✅ ${f}: bytes/op improved ${base.bytes_per_op} -> ${cur.bytes_per_op} (${dB}) — rerun --update to lock in${tNote}`);
  } else {
    console.log(`  ✅ ${f}: ${cur.bytes_per_op} B/op (unchanged)${tNote}`);
  }
}

function dPct(cur, base) {
  if (!base) return "n/a";
  const p = ((cur - base) / base) * 100;
  return `${p >= 0 ? "+" : ""}${p.toFixed(0)}%`;
}

console.log("");
if (failed) {
  console.error(`[bench-regression] FAIL: ${failed} allocation regression(s). If intentional, rerun with --update.`);
  process.exit(1);
}
console.log(`[bench-regression] ok: ${FIXTURES.length} fixtures, no allocation regression.`);
