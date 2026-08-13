import test from "node:test";
import assert from "node:assert/strict";

import {
  branchFocusedExtraEntries,
  buildJsonReport,
  buildTextReport,
  computeNextBranchEntries,
  parseArgs,
  presetExtraEntries,
  topBranchUnionGaps,
} from "./coverage_suite_next_branches.mjs";

test("topBranchUnionGaps: drops malformed rows and keeps well-formed ones", () => {
  const report = {
    top_branch_union_gaps: [
      { fn: "f", branch_hit: 1, branch_total: 4, branch_miss: 3 },
      { fn: "g", branch_hit: 1, branch_total: 2 },
      { branch_hit: 0, branch_total: 2, branch_miss: 2 },
    ],
  };
  assert.deepEqual(topBranchUnionGaps(report), [
    { fn: "f", branch_hit: 1, branch_total: 4, branch_miss: 3 },
  ]);
});

test("topBranchUnionGaps: absent section yields no rows", () => {
  assert.deepEqual(topBranchUnionGaps({}), []);
});

test("buildTextReport: reports the branch union and its gaps", () => {
  const text = buildTextReport({
    branch_union: { hit: 3, total: 10, rate: 30.0, exact: true },
    top_branch_union_gaps: [{ fn: "f", branch_hit: 1, branch_total: 4, branch_miss: 3 }],
    cases: [],
  }, "r.json");
  assert.match(text, /branch_union: 3\/10 \(30%\)/);
  assert.match(text, /- f 3 missed \(1\/4\)/);
});

test("buildTextReport: marks a non-exact branch union as a lower bound", () => {
  const text = buildTextReport({
    branch_union: { hit: 3, total: 10, rate: 30.0, exact: false },
    cases: [],
  }, "r.json");
  assert.match(text, /branch_union: 3\/10 \(30%\) \(lower bound\)/);
});

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
      { entry_path: "lib/@vibe/compiler/tests/fixture_test.vibe" },
      { entry_path: "lib/@vibe/compiler/tests/lexer_test.vibe" },
      { entry_path: "lib/@vibe/compiler/tests/printer_test.vibe" },
    ],
  };
  assert.deepEqual(computeNextBranchEntries(report), [
    "lib/@vibe/compiler/tests/checker_test.vibe",
    "lib/@vibe/compiler/tests/checker_builtins_test.vibe",
    "lib/@vibe/compiler/tests/s5_test.vibe",
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
      { entry_path: "lib/@vibe/compiler/tests/fixture_test.vibe" },
      { entry_path: "lib/@vibe/compiler/tests/lexer_test.vibe" },
      { entry_path: "lib/@vibe/compiler/tests/printer_test.vibe" },
    ],
    top_branch_gaps: [
      {
        entry_path: "lib/@vibe/compiler/tests/checker_test.vibe",
        branch_miss: 120,
        branch_total: 400,
        branch_hit: 280,
      },
    ],
    top_non_aggregate_branch_gaps: [
      {
        entry_path: "lib/@vibe/compiler/stage2_coverage_run.vibe",
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
    /vibe\/compiler\/tests\/checker_test\.vibe 120 missed \(280\/400\)/,
  );
  assert.match(text, /top_non_aggregate_branch_gaps:/);
  assert.match(
    text,
    /vibe\/compiler\/stage2_coverage_run\.vibe 5354 missed \(0\/5354\)/,
  );
  assert.match(
    text,
    /suggested_extra_entries: lib\/@vibe\/compiler\/tests\/checker_test\.vibe,lib\/@vibe\/compiler\/tests\/checker_builtins_test\.vibe,lib\/@vibe\/compiler\/tests\/s5_test\.vibe/,
  );
});

test("buildJsonReport: emits suggested entries and gaps", () => {
  const report = {
    cases: [{ entry_path: "lib/@vibe/compiler/tests/fixture_test.vibe" }],
    top_branch_gaps: [
      {
        entry_path: "lib/@vibe/compiler/tests/checker_test.vibe",
        branch_miss: 120,
        branch_total: 400,
        branch_hit: 280,
      },
    ],
    top_non_aggregate_branch_gaps: [
      {
        entry_path: "lib/@vibe/compiler/stage2_coverage_run.vibe",
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
    "lib/@vibe/compiler/tests/lexer_test.vibe",
    "lib/@vibe/compiler/tests/printer_test.vibe",
    "lib/@vibe/compiler/tests/checker_test.vibe",
    "lib/@vibe/compiler/tests/checker_builtins_test.vibe",
    "lib/@vibe/compiler/tests/s5_test.vibe",
  ]);
});
