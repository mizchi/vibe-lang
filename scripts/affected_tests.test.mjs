import test from "node:test";
import assert from "node:assert/strict";

import { affectedFrom, classifyChanges, isGraphReasonable, parseArgs } from "./affected_tests.mjs";

test("parseArgs: defaults", () => {
  const args = parseArgs([]);
  assert.equal(args.changedFrom, "origin/main");
  assert.equal(args.changed, null);
  assert.equal(args.jobs, 4);
  assert.equal(args.indexOnly, false);
});

test("parseArgs: repeated --changed accumulates", () => {
  const args = parseArgs(["--changed", "a.vibe", "--changed", "b.vibe"]);
  assert.deepEqual(args.changed, ["a.vibe", "b.vibe"]);
});

test("parseArgs: rejects a non-positive --jobs", () => {
  assert.throws(() => parseArgs(["--jobs", "0"]), /positive integer/);
  assert.throws(() => parseArgs(["--jobs", "x"]), /positive integer/);
});

test("isGraphReasonable: only vibe sources under lib/ are covered", () => {
  assert.equal(isGraphReasonable("lib/@vibe/compiler/codegen/codegen.vibe"), true);
  assert.equal(isGraphReasonable("lib/@vibe/compiler/loader/index.vpkg"), true);
  // The import graph says nothing about these, so they must NOT be silently
  // treated as "affects nothing".
  assert.equal(isGraphReasonable("scripts/unit_test_runner.sh"), false);
  assert.equal(isGraphReasonable("bootstrap/seed.json"), false);
  assert.equal(isGraphReasonable("fixtures/foo.vibe"), false);
  assert.equal(isGraphReasonable("Taskfile.pkl"), false);
});

test("classifyChanges: splits covered from uncovered paths", () => {
  const { known, unknown } = classifyChanges(["lib/a.vibe", "scripts/x.sh", "lib/b.vpkg"]);
  assert.deepEqual(known, ["lib/a.vibe", "lib/b.vpkg"]);
  assert.deepEqual(unknown, ["scripts/x.sh"]);
});

// The whole point of the tool: a test in an unrelated DIRECTORY that imports
// the changed file transitively must be selected. The directory-based resolver
// this replaces misses exactly this case.
test("affectedFrom: selects a transitively-importing test in another directory", () => {
  const index = {
    "lib/pkg/a_test.vibe": { deps: ["lib/other/mid.vibe"] },
    "lib/other/mid.vibe": { deps: ["lib/deep/leaf.vibe"] },
    "lib/deep/leaf.vibe": { deps: [] },
    "lib/unrelated/b_test.vibe": { deps: ["lib/unrelated/util.vibe"] },
    "lib/unrelated/util.vibe": { deps: [] },
  };
  const entries = ["lib/pkg/a_test.vibe", "lib/unrelated/b_test.vibe"];

  const { selected } = affectedFrom(index, ["lib/deep/leaf.vibe"], entries);

  assert.deepEqual(selected, ["lib/pkg/a_test.vibe"]);
});

test("affectedFrom: a changed test file selects itself with no importer", () => {
  const index = { "lib/pkg/a_test.vibe": { deps: [] } };
  const { selected } = affectedFrom(index, ["lib/pkg/a_test.vibe"], ["lib/pkg/a_test.vibe"]);
  assert.deepEqual(selected, ["lib/pkg/a_test.vibe"]);
});

test("affectedFrom: a change nothing imports selects nothing", () => {
  const index = {
    "lib/pkg/a_test.vibe": { deps: ["lib/pkg/util.vibe"] },
    "lib/pkg/util.vibe": { deps: [] },
    "lib/orphan.vibe": { deps: [] },
  };
  const { selected } = affectedFrom(index, ["lib/orphan.vibe"], ["lib/pkg/a_test.vibe"]);
  assert.deepEqual(selected, []);
});

test("affectedFrom: a shared dep selects every importing test, deduped and sorted", () => {
  const index = {
    "lib/z_test.vibe": { deps: ["lib/core.vibe"] },
    "lib/a_test.vibe": { deps: ["lib/mid.vibe", "lib/core.vibe"] },
    "lib/mid.vibe": { deps: ["lib/core.vibe"] },
    "lib/core.vibe": { deps: [] },
  };
  const entries = ["lib/z_test.vibe", "lib/a_test.vibe"];

  const { selected } = affectedFrom(index, ["lib/core.vibe"], entries);

  assert.deepEqual(selected, ["lib/a_test.vibe", "lib/z_test.vibe"]);
});

// An import cycle must not hang the upward walk. The compiler rejects cycles,
// but a stale index can still contain one, and hanging is a worse failure than
// over-selecting.
test("affectedFrom: terminates on a cyclic index", () => {
  const index = {
    "lib/a.vibe": { deps: ["lib/b.vibe"] },
    "lib/b.vibe": { deps: ["lib/a.vibe"] },
    "lib/t_test.vibe": { deps: ["lib/a.vibe"] },
  };
  const { selected } = affectedFrom(index, ["lib/b.vibe"], ["lib/t_test.vibe"]);
  assert.deepEqual(selected, ["lib/t_test.vibe"]);
});

test("affectedFrom: explain path runs from the change up to the entry", () => {
  const index = {
    "lib/t_test.vibe": { deps: ["lib/mid.vibe"] },
    "lib/mid.vibe": { deps: ["lib/leaf.vibe"] },
    "lib/leaf.vibe": { deps: [] },
  };
  const { via } = affectedFrom(index, ["lib/leaf.vibe"], ["lib/t_test.vibe"]);
  assert.deepEqual(via.get("lib/t_test.vibe"), ["lib/leaf.vibe", "lib/mid.vibe", "lib/t_test.vibe"]);
});
