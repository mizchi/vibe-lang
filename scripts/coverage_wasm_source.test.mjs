import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  applySourceNoiseExclusion,
  buildSourceDepSignature,
  buildSuiteCaseText,
  evaluateKpi,
  isCoverageNoiseLine,
  parseArgs,
} from "./coverage_wasm_source.mjs";

test("isCoverageNoiseLine: import list identifier is excluded", () => {
  const sourceLines = [
    "import {",
    "  a,",
    "  b",
    "} from \"./x.vibe\"",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), true);
});

test("isCoverageNoiseLine: path import list identifier is excluded", () => {
  const sourceLines = [
    "import ./types.vibe {",
    "  Type, TypeEnv, env_bind, types_equal",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), true);
});

test("isCoverageNoiseLine: block closing brace is excluded", () => {
  const sourceLines = [
    "test \"x\" {",
    "  assert(true)",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
});

test("isCoverageNoiseLine: else bridge line is excluded", () => {
  const sourceLines = [
    "if cond {",
    "  left()",
    "} else {",
    "  right()",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
});

test("isCoverageNoiseLine: handle bridge line is excluded", () => {
  const sourceLines = [
    "let ok = handle {",
    "  run()",
    "} with Exception {",
    "  Throw(_) => false;",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
});

test("isCoverageNoiseLine: executable line is not excluded", () => {
  const sourceLines = [
    "test \"x\" {",
    "  assert(true)",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), false);
});

test("isCoverageNoiseLine: comment line is excluded", () => {
  const sourceLines = [
    "//# Header",
    "let x = 1",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 1), true);
});

test("isCoverageNoiseLine: export list item is excluded", () => {
  const sourceLines = [
    "export {",
    "  Token, token_to_string",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), true);
});

test("isCoverageNoiseLine: export list header is excluded", () => {
  const sourceLines = [
    "export ./parser.vibe {",
    "  parse",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 1), true);
});

test("isCoverageNoiseLine: multiline array literal items are excluded", () => {
  const sourceLines = [
    "assert(tokens_match(tokens, [",
    "  TInt(1),",
    '  TIdent("x"),',
    "  TPlus,",
    "  TEof",
    "]))",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), true);
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
  assert.equal(isCoverageNoiseLine(sourceLines, 4), true);
  assert.equal(isCoverageNoiseLine(sourceLines, 5), true);
});

test("isCoverageNoiseLine: comma-only continuation line is excluded", () => {
  const sourceLines = [
    "match value {",
    "  Some(result) => ok(result)",
    "  ,",
    "  None => false",
    "}",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
});

test("isCoverageNoiseLine: array close continuation line is excluded", () => {
  const sourceLines = [
    "assert(types_equal(ty, CtFn([",
    "  CtString,",
    "  CtString",
    "], CtString, false)))",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 4), true);
});

test("isCoverageNoiseLine: closing array call line is excluded", () => {
  const sourceLines = [
    "assert(tokens_match(tokens, [",
    "  TInt(1),",
    "  TEof",
    "]))",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 4), true);
});

test("isCoverageNoiseLine: standalone array closing line is excluded", () => {
  const sourceLines = [
    "let values = [",
    "  one,",
    "  two,",
    "]",
    "use(values)",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 4), true);
});

test("isCoverageNoiseLine: tuple array item line is excluded", () => {
  const sourceLines = [
    "let sources = [",
    '  ("a.vibe", "export let x = 1"),',
    '  ("b.vibe", "export let y = 2")',
    "]",
  ];
  assert.equal(isCoverageNoiseLine(sourceLines, 2), true);
  assert.equal(isCoverageNoiseLine(sourceLines, 3), true);
});

test("parseArgs: --invoke can be provided multiple times", () => {
  const args = parseArgs([
    "a.wasm",
    "a.wasm.cov.json",
    "--invoke",
    "setup",
    "--invoke",
    "run_extra",
  ]);
  assert.deepEqual(args.invokeNames, ["setup", "run_extra"]);
});

test("parseArgs: kpi threshold options are parsed", () => {
  const args = parseArgs([
    "a.wasm",
    "a.wasm.cov.json",
    "--min-point-rate",
    "12.5",
    "--min-line-rate",
    "95",
    "--min-branch-rate",
    "8",
  ]);
  assert.equal(args.minPointRate, 12.5);
  assert.equal(args.minLineRate, 95);
  assert.equal(args.minBranchRate, 8);
});

test("evaluateKpi: pass and fail by thresholds", () => {
  const report = {
    stats: {
      point_total: 100,
      point_hit: 20,
      line_total: 50,
      line_hit: 50,
      branch_total: 80,
      branch_hit: 12,
    },
  };
  const pass = evaluateKpi(report, 20, 100, 15);
  assert.equal(pass.ok, true);
  assert.deepEqual(pass.failures, []);

  const fail = evaluateKpi(report, 25, 100, 20);
  assert.equal(fail.ok, false);
  assert.equal(fail.failures.length, 2);
  assert.match(fail.failures.join(" "), /point_coverage/);
  assert.match(fail.failures.join(" "), /branch_coverage/);
});

test("applySourceNoiseExclusion: excluded lines are removed from line KPI", () => {
  const sourceLines = [
    "import {",
    "  i32_and,",
    "} from \"./opcodes.vibe\"",
    "test \"x\" {",
    "  assert(true)",
    "}",
  ];
  const lines = [
    { line: 2, hit: false, count: 0 },
    { line: 3, hit: false, count: 0 },
    { line: 5, hit: true, count: 1 },
    { line: 6, hit: false, count: 0 },
  ];
  const result = applySourceNoiseExclusion(lines, sourceLines);
  assert.equal(result.line_total, 1);
  assert.equal(result.line_hit, 1);
  assert.equal(result.line_excluded_total, 3);
  assert.equal(result.lines.filter((line) => line.excluded).length, 3);
});

test("buildSourceDepSignature: follows relative and root imports with lock sidecars", () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vibe_cov_dep_sig."));
  const write = (relPath, content) => {
    const absPath = path.join(tmpRoot, relPath);
    fs.mkdirSync(path.dirname(absPath), { recursive: true });
    fs.writeFileSync(absPath, content);
    return absPath;
  };

  const entryPath = write(
    "workspace/main.vibe",
    [
      "import ./dep.vibe { dep }",
      "import /vibe/prelude/option.vibe { unwrap_or }",
      'let s = "import ./ignored.vibe { nope }"',
      "// import ./comment_only.vibe { nope }",
      "",
    ].join("\n"),
  );
  write("workspace/dep.vibe", "export let dep = 1\n");
  write("workspace/index.lock", "{}\n");
  write("vibe/prelude/option.vibe", "export let unwrap_or = (x, y) -> x\n");
  write("vibe/prelude/index.lock", "{}\n");

  const signature = buildSourceDepSignature(entryPath, { projectRoot: tmpRoot });

  assert.match(signature, /workspace\/main\.vibe\t/);
  assert.match(signature, /workspace\/dep\.vibe\t/);
  assert.match(signature, /workspace\/index\.lock\t/);
  assert.match(signature, /vibe\/prelude\/option\.vibe\t/);
  assert.match(signature, /vibe\/prelude\/index\.lock\t/);
  assert.doesNotMatch(signature, /ignored\.vibe/);
  assert.doesNotMatch(signature, /comment_only\.vibe/);
});

test("buildSuiteCaseText: summary-only keeps case branch stats for ranking", () => {
  const compact = buildSuiteCaseText(
    {
      entry_path: "lib/@vibe/compiler/stage2_coverage_run.vibe",
      execution: { ok: true, error: "" },
      stats: {
        point_total: 12,
        point_hit: 1,
        line_total: 4,
        line_hit: 3,
        branch_total: 20,
        branch_hit: 5,
      },
      line_points: "1:1",
      branch_points: "0:1,1:0",
    },
    { summaryOnly: true },
  );

  assert.match(compact, /summary_only\t1/);
  assert.match(compact, /point_total\t0/);
  assert.match(compact, /branch_total\t0/);
  assert.match(compact, /case_branch_total\t20/);
  assert.match(compact, /case_branch_hit\t5/);
  assert.doesNotMatch(compact, /branch_points\t/);
});
