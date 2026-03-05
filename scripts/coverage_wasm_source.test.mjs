import test from "node:test";
import assert from "node:assert/strict";

import {
  applySourceNoiseExclusion,
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

test("isCoverageNoiseLine: block closing brace is excluded", () => {
  const sourceLines = [
    "test \"x\" {",
    "  assert(true)",
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
