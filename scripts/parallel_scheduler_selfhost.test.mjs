import assert from "node:assert/strict";
import test from "node:test";

import {
  runParallelProject,
  validateParallelTrace,
} from "./parallel_scheduler_prototype.mjs";

const compilerWasm = process.env.VIBE_PARALLEL_COMPILER_WASM;

if (!compilerWasm) {
  throw new Error(
    "VIBE_PARALLEL_COMPILER_WASM must point to a current selfhost compiler",
  );
}

function checkerProject() {
  return [
    {
      id: "invalid",
      dependencies: [],
      source: "let answer = (",
    },
    {
      id: "valid-a",
      dependencies: [],
      source: "let answer = () -> Int { 40 + 2 }",
    },
    {
      id: "valid-b",
      dependencies: [],
      source: "let identity = (value: String) -> String { value }",
    },
  ];
}

test("selfhost checker outcomes are deterministic for jobs=1/2/4", async () => {
  const execution = { kind: "selfhost-check", compilerWasm };
  const sequential = await runParallelProject(checkerProject(), {
    jobs: 1,
    execution,
  });
  const twoWorkers = await runParallelProject(checkerProject(), {
    jobs: 2,
    execution,
  });
  const fourWorkers = await runParallelProject(checkerProject(), {
    jobs: 4,
    execution,
  });

  assert.equal(twoWorkers.output, sequential.output);
  assert.equal(fourWorkers.output, sequential.output);
  assert.equal(
    validateParallelTrace(checkerProject(), twoWorkers.trace, 2).maxRunning,
    2,
  );
  assert.equal(sequential.outcomes.get("valid-a").kind, "checked");
  assert.equal(sequential.outcomes.get("valid-b").kind, "checked");

  const invalid = sequential.outcomes.get("invalid");
  assert.equal(invalid.kind, "diagnosed");
  assert.equal(invalid.diagnostics[0].code, "E_SELFHOST_CHECK");
  assert.match(invalid.diagnostics[0].message, /.+/);
});

test("a diagnosed dependency prevents a dependent selfhost check", async () => {
  const run = await runParallelProject(
    [
      { id: "base", dependencies: [], source: "let answer = (" },
      {
        id: "app",
        dependencies: ["base"],
        source: "let answer = () -> Int { 42 }",
      },
    ],
    {
      jobs: 2,
      execution: { kind: "selfhost-check", compilerWasm },
    },
  );

  assert.equal(run.outcomes.get("base").kind, "diagnosed");
  assert.deepEqual(run.outcomes.get("app"), {
    kind: "diagnosed",
    diagnostics: [
      {
        module: "app",
        start: 0,
        end: 0,
        code: "E_DEPENDENCY",
        message: "dependency diagnostics: base",
      },
    ],
  });
});
