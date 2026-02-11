import test from "node:test";
import assert from "node:assert/strict";

import {
  applySourceNoiseExclusion,
  isCoverageNoiseLine,
} from "./coverage_wasm_source.mjs";

test("isCoverageNoiseLine: import list identifier is excluded", () => {
  const sourceLines = [
    "import {",
    "  a,",
    "  b",
    "} from \"./x.xsh\"",
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

test("applySourceNoiseExclusion: excluded lines are removed from line KPI", () => {
  const sourceLines = [
    "import {",
    "  i32_and,",
    "} from \"./opcodes.xsh\"",
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
