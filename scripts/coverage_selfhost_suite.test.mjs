import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  buildSuiteReport,
  evaluateKpi,
  parseArgs,
} from "./coverage_selfhost_suite.mjs";

test("parseArgs: parses kpi options", () => {
  const args = parseArgs([
    "reports.txt",
    "--json",
    "out.json",
    "--summary",
    "out.txt",
    "--min-point-rate",
    "14",
    "--min-line-rate",
    "95",
    "--min-branch-rate",
    "12",
  ]);
  assert.equal(args.listPath, "reports.txt");
  assert.equal(args.reportJsonPath, "out.json");
  assert.equal(args.summaryPath, "out.txt");
  assert.equal(args.minPointRate, 14);
  assert.equal(args.minLineRate, 95);
  assert.equal(args.minBranchRate, 12);
});

test("buildSuiteReport + evaluateKpi: aggregates stats", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-selfhost-suite-"));
  const reportA = path.join(dir, "a.report.json");
  const reportB = path.join(dir, "b.report.json");
  fs.writeFileSync(
    reportA,
    JSON.stringify({
      entry_path: "vibe/compiler/selfhost_coverage_run.vibe",
      execution: { ok: true, error: null },
      stats: {
        point_total: 200,
        point_hit: 60,
        line_total: 30,
        line_hit: 30,
        branch_total: 120,
        branch_hit: 40,
      },
      lines: [
        { line: 1, hit: true, excluded: false },
        { line: 2, hit: true, excluded: false },
      ],
    }),
  );
  fs.writeFileSync(
    reportB,
    JSON.stringify({
      entry_path: "vibe/compiler/index.vibe",
      execution: { ok: true, error: null },
      stats: {
        point_total: 100,
        point_hit: 10,
        line_total: 20,
        line_hit: 10,
        branch_total: 80,
        branch_hit: 8,
      },
      lines: [
        { line: 1, hit: false, excluded: false },
        { line: 2, hit: false, excluded: true },
      ],
    }),
  );

  const report = buildSuiteReport([reportA, reportB]);
  assert.equal(report.case_count, 2);
  assert.equal(report.execution.trap_case_count, 0);
  assert.equal(report.stats.point_total, 300);
  assert.equal(report.stats.point_hit, 70);
  assert.equal(report.stats.line_total, 3);
  assert.equal(report.stats.line_hit, 2);
  assert.equal(report.stats.branch_total, 200);
  assert.equal(report.stats.branch_hit, 48);

  const pass = evaluateKpi(report, 20, 60, 20);
  assert.equal(pass.ok, true);

  const fail = evaluateKpi(report, 30, 70, 30);
  assert.equal(fail.ok, false);
  assert.match(fail.failures.join(" "), /point_coverage/);
  assert.match(fail.failures.join(" "), /line_coverage/);
  assert.match(fail.failures.join(" "), /branch_coverage/);
});
