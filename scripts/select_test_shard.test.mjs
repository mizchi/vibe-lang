import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  loadWeights,
  normalizeRepoPath,
  parseArgs,
  selectWeightedShard,
} from "./select_test_shard.mjs";

test("normalizeRepoPath converts absolute paths to repo-relative slash paths", () => {
  const root = path.join(os.tmpdir(), "repo");
  assert.equal(
    normalizeRepoPath(path.join(root, "lib", "@vibe", "compiler", "a_test.vibe"), root),
    "lib/@vibe/compiler/a_test.vibe",
  );
});

test("selectWeightedShard balances heavy files and preserves original order within a shard", () => {
  const files = ["a_test.vibe", "b_test.vibe", "c_test.vibe", "d_test.vibe", "e_test.vibe"];
  const weights = {
    "a_test.vibe": 1,
    "b_test.vibe": 10,
    "c_test.vibe": 9,
    "d_test.vibe": 1,
    "e_test.vibe": 1,
  };

  assert.deepEqual(selectWeightedShard(files, { index: 0, total: 2, weights }), [
    "b_test.vibe",
    "d_test.vibe",
  ]);
  assert.deepEqual(selectWeightedShard(files, { index: 1, total: 2, weights }), [
    "a_test.vibe",
    "c_test.vibe",
    "e_test.vibe",
  ]);
});

test("loadWeights accepts missing files as empty weights", () => {
  assert.deepEqual(loadWeights(path.join(os.tmpdir(), "missing-selfhost-weights.json")), {});
});

test("loadWeights ignores non-finite or negative weights", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "selfhost-shard-"));
  const weightsPath = path.join(dir, "weights.json");
  fs.writeFileSync(
    weightsPath,
    JSON.stringify({
      keep: 3,
      "nested\\path": 2,
      negative: -1,
      stringy: "4",
      bad: "nan",
    }),
  );
  assert.deepEqual(loadWeights(weightsPath), { keep: 3, "nested/path": 2, stringy: 4 });
});

test("parseArgs separates selector options from file list", () => {
  assert.deepEqual(
    parseArgs(["--index", "1", "--total", "4", "--root", "/repo", "--weights", "weights.json", "--", "a", "b"]),
    {
      index: "1",
      total: "4",
      root: "/repo",
      weightsPath: "weights.json",
      files: ["a", "b"],
    },
  );
});
