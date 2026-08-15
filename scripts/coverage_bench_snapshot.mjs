#!/usr/bin/env node
// Extract the compact coverage snapshot the continuous perf pipeline stores on
// the bench-data branch (ci.yml coverage-suite job, main-only → rendered into
// every PR's perf report by scripts/bench_report.mjs).
//
//   node scripts/coverage_bench_snapshot.mjs suite_report.json [prev_snapshot.json]
//
// stdout: one compact JSON object. `prev` carries the PREVIOUS snapshot's
// headline rates (if a previous snapshot was given and parseable) so the
// report can show a main-to-main trend without fetching the whole history.
//
// The union metrics are the source-coverage ones (each function/branch
// counted once no matter how many test entries link it — #1556); the
// entry-weighted pair is deliberately NOT propagated here: its denominator
// dilutes with every added test entry, which reads as a regression when
// coverage actually grew (see the rebaseline notes in coverage_suite.sh).
import { readFileSync, existsSync } from "node:fs";

const [reportPath, prevPath] = process.argv.slice(2);
if (!reportPath) {
  console.error("usage: coverage_bench_snapshot.mjs suite_report.json [prev_snapshot.json]");
  process.exit(2);
}
const r = JSON.parse(readFileSync(reportPath, "utf8"));
for (const k of ["function_union", "branch_union"]) {
  if (!r[k] || typeof r[k].hit !== "number" || typeof r[k].total !== "number") {
    console.error(`coverage_bench_snapshot: suite report has no usable ${k} — refusing to emit a partial snapshot`);
    process.exit(1);
  }
}

let prev = null;
if (prevPath && existsSync(prevPath)) {
  try {
    const p = JSON.parse(readFileSync(prevPath, "utf8"));
    if (p?.function_union?.rate != null && p?.branch_union?.rate != null) {
      prev = {
        commit: p.commit || null,
        date: p.date || null,
        function_union_rate: p.function_union.rate,
        branch_union_rate: p.branch_union.rate,
      };
    }
  } catch {
    // A corrupt previous snapshot must not block recording the current one —
    // the trend line just goes missing for one run.
  }
}

const doc = {
  schema: 1,
  commit: process.env.GITHUB_SHA || "",
  date: new Date().toISOString(),
  function_union: { hit: r.function_union.hit, total: r.function_union.total, rate: r.function_union.rate },
  branch_union: {
    hit: r.branch_union.hit,
    total: r.branch_union.total,
    rate: r.branch_union.rate,
    exact: r.branch_union.exact !== false,
  },
  entries_total: r.entries_total ?? null,
  entries_passed: r.entries_passed ?? null,
  case_rate: r.case_rate ?? null,
  prev,
};
console.log(JSON.stringify(doc, null, 2));
