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

// #906 Phase 2. Module ids are path-like because a job's `path` row is the
// base directory its imports resolve against. The path is never opened --
// /virtual does not exist, which is the point: a worker that fell back to
// reading the real filesystem would fail here rather than quietly succeed.
const DEP_ID = "/virtual/pkg/dep.vibe";
const MAIN_ID = "/virtual/pkg/main.vibe";

function importDagProject(argument) {
  return [
    {
      id: DEP_ID,
      dependencies: [],
      source: "export fn dep_value(n: Int) -> Int {\n  n + 41\n}\n",
    },
    {
      id: MAIN_ID,
      dependencies: [DEP_ID],
      source: `import ./dep.vibe {\n  dep_value\n}\n\nexport fn answer() -> Int {\n  dep_value(${argument})\n}\n`,
    },
  ];
}

test("a dependency's interface crosses the worker boundary", async () => {
  const execution = { kind: "selfhost-check", compilerWasm };

  const ok = await runParallelProject(importDagProject("1"), { jobs: 2, execution });
  assert.equal(ok.outcomes.get(DEP_ID).kind, "checked");
  assert.equal(ok.outcomes.get(MAIN_ID).kind, "checked");
  assert.match(ok.outcomes.get(DEP_ID).artifact.env, /dep_value/);

  // The discriminator. Merely CALLING an imported name proves nothing: an
  // unresolved import is lenient, so a module that calls dep_value(1)
  // checks clean whether or not the dependency's environment was ever
  // installed. Passing a String is an error only if the real SIGNATURE
  // arrived across the boundary.
  const bad = await runParallelProject(importDagProject('"not an int"'), {
    jobs: 2,
    execution,
  });
  const diagnosed = bad.outcomes.get(MAIN_ID);
  assert.equal(diagnosed.kind, "diagnosed");
  assert.match(diagnosed.diagnostics[0].message, /expected Int, got String/);
});

test("import DAG outcomes are identical for jobs=1/2/4", async () => {
  const execution = { kind: "selfhost-check", compilerWasm };
  const sequential = await runParallelProject(importDagProject("1"), {
    jobs: 1,
    execution,
  });
  for (const jobs of [2, 4]) {
    const parallel = await runParallelProject(importDagProject("1"), {
      jobs,
      execution,
    });
    assert.equal(parallel.output, sequential.output, `jobs=${jobs}`);
  }
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
