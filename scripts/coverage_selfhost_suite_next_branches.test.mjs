import test from "node:test";
import assert from "node:assert/strict";

import {
  branchFocusedExtraEntries,
  buildJsonReport,
  buildTextReport,
  computeNextBranchEntries,
  parseArgs,
  presetExtraEntries,
} from "./coverage_selfhost_suite_next_branches.mjs";

test("parseArgs: default path and text format", () => {
  const args = parseArgs([]);
  assert.equal(args.reportPath, "_build/coverage/selfhost-suite/selfhost_suite.report.json");
  assert.equal(args.format, "text");
  assert.equal(args.preset, null);
});

test("parseArgs: preset branch with env format", () => {
  const args = parseArgs(["--preset", "branch", "--format", "env"]);
  assert.equal(args.reportPath, "_build/coverage/selfhost-suite/selfhost_suite.report.json");
  assert.equal(args.format, "env");
  assert.equal(args.preset, "branch");
});

test("presetExtraEntries: branch returns branch-focused preset entries", () => {
  assert.deepEqual(presetExtraEntries("branch"), branchFocusedExtraEntries);
});

test("computeNextBranchEntries: returns missing branch-focused preset entries", () => {
  const report = {
    cases: [
      { entry_path: "vibe/compiler/eval_e2e_test.vibe" },
      { entry_path: "vibe/compiler/fixture_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost2_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost3_test.vibe" },
    ],
  };
  assert.deepEqual(computeNextBranchEntries(report), [
    "vibe/compiler/lexer_test.vibe",
    "vibe/compiler/printer_test.vibe",
    "vibe/compiler/eval_builtins_test.vibe",
    "vibe/compiler/checker_test.vibe",
  ]);
});

test("computeNextBranchEntries: empty when all preset entries already exist", () => {
  const report = {
    cases: branchFocusedExtraEntries.map((entry_path) => ({ entry_path })),
  };
  assert.deepEqual(computeNextBranchEntries(report), []);
});

test("buildTextReport: includes top gaps and suggested entries", () => {
  const report = {
    cases: [
      { entry_path: "vibe/compiler/eval_e2e_test.vibe" },
      { entry_path: "vibe/compiler/fixture_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost2_test.vibe" },
      { entry_path: "vibe/compiler/eval_selfhost3_test.vibe" },
    ],
    top_branch_gaps: [
      {
        entry_path: "vibe/compiler/eval_selfhost_test.vibe",
        branch_miss: 120,
        branch_total: 400,
        branch_hit: 280,
      },
    ],
    top_non_aggregate_branch_gaps: [
      {
        entry_path: "vibe/compiler/selfhost_stage2_coverage_run.vibe",
        branch_miss: 5354,
        branch_total: 5354,
        branch_hit: 0,
      },
    ],
  };
  const text = buildTextReport(report, "/tmp/selfhost_suite.report.json");
  assert.match(text, /top_branch_gaps:/);
  assert.match(
    text,
    /vibe\/compiler\/eval_selfhost_test\.vibe 120 missed \(280\/400\)/,
  );
  assert.match(text, /top_non_aggregate_branch_gaps:/);
  assert.match(
    text,
    /vibe\/compiler\/selfhost_stage2_coverage_run\.vibe 5354 missed \(0\/5354\)/,
  );
  assert.match(
    text,
    /suggested_extra_entries: vibe\/compiler\/lexer_test\.vibe,vibe\/compiler\/printer_test\.vibe,vibe\/compiler\/eval_builtins_test\.vibe,vibe\/compiler\/checker_test\.vibe/,
  );
});

test("buildJsonReport: emits suggested entries and gaps", () => {
  const report = {
    cases: [{ entry_path: "vibe/compiler/eval_e2e_test.vibe" }],
    top_branch_gaps: [
      {
        entry_path: "vibe/compiler/eval_selfhost_test.vibe",
        branch_miss: 120,
        branch_total: 400,
        branch_hit: 280,
      },
    ],
    top_non_aggregate_branch_gaps: [
      {
        entry_path: "vibe/compiler/selfhost_stage2_coverage_run.vibe",
        branch_miss: 5354,
        branch_total: 5354,
        branch_hit: 0,
      },
    ],
  };
  const jsonText = buildJsonReport(report, "/tmp/selfhost_suite.report.json");
  const parsed = JSON.parse(jsonText);
  assert.equal(parsed.report_path, "/tmp/selfhost_suite.report.json");
  assert.equal(parsed.top_branch_gaps[0].branch_miss, 120);
  assert.equal(parsed.top_non_aggregate_branch_gaps[0].branch_miss, 5354);
  assert.deepEqual(parsed.suggested_extra_entries, [
    "vibe/compiler/fixture_test.vibe",
    "vibe/compiler/eval_selfhost_test.vibe",
    "vibe/compiler/eval_selfhost2_test.vibe",
    "vibe/compiler/eval_selfhost3_test.vibe",
    "vibe/compiler/lexer_test.vibe",
    "vibe/compiler/printer_test.vibe",
    "vibe/compiler/eval_builtins_test.vibe",
    "vibe/compiler/checker_test.vibe",
  ]);
});
