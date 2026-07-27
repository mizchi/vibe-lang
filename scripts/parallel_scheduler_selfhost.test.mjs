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

  // Both fingerprints must be check_module's CANONICAL build_fingerprint
  // ("<len>:<hash>:<hash>"), not the worker's synthetic sha256-of-JSON
  // fallback (64 hex chars). An earlier cut had the coordinator invent a
  // fingerprint that check_module never saw and simply echoed back, which
  // meant nothing a worker published could ever land at the persistent-
  // cache path a serial compile would actually look under -- silently
  // useless. A regression back to the synthetic fallback would still make
  // every other assertion in this file pass, since jobs=1/2/4 determinism
  // and dependency-gating don't care WHAT the fingerprint is, only that
  // it's consistent -- so this shape check is the one place that catches it.
  const CANONICAL_FP = /^\d+:\d+:\d+$/;
  assert.match(ok.outcomes.get(DEP_ID).artifact.fingerprint, CANONICAL_FP);
  assert.match(ok.outcomes.get(MAIN_ID).artifact.fingerprint, CANONICAL_FP);

  // Sensitivity: MAIN's fingerprint must depend on DEP's, not just on
  // MAIN's own source. Re-running with an unrelated extra dependency-free
  // module doesn't change DEP, but changing DEP's source must change
  // MAIN's fingerprint even though MAIN's own source is byte-identical.
  const changedDep = await runParallelProject(
    [
      { id: DEP_ID, dependencies: [], source: "export fn dep_value(n: Int) -> Int {\n  n + 42\n}\n" },
      importDagProject("1")[1],
    ],
    { jobs: 2, execution },
  );
  assert.notEqual(
    changedDep.outcomes.get(MAIN_ID).artifact.fingerprint,
    ok.outcomes.get(MAIN_ID).artifact.fingerprint,
    "MAIN's fingerprint did not change when DEP's source changed -- MAIN's own identity is not folding its dependency's",
  );

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

// #1126 Codex review. A module can import the same dependency through two
// SEPARATE import statements (valid vibe; the serial compiler accepts it),
// and check_module's build_fingerprint folds a dependency's fingerprint
// once PER OCCURRENCE. `dependencies` has to stay deduped (the scheduler's
// own uniqueness requirement -- a module only needs each distinct
// dependency ready once), so `dependencyOccurrences` is what actually
// drives the fold. Isolated from file discovery here: this constructs the
// module list by hand, differing ONLY in whether MAIN's
// dependencyOccurrences repeats DEP once or twice, and asserts the
// resulting fingerprints differ -- proving the occurrence COUNT itself
// reaches build_fingerprint, not just DEP's identity.
test("repeated dependency occurrences fold into the fingerprint multiple times", async () => {
  const execution = { kind: "selfhost-check", compilerWasm };
  const depModule = { id: DEP_ID, dependencies: [], source: "export fn dep_value(n: Int) -> Int {\n  n + 41\n}\n" };
  const mainSource = "import ./dep.vibe {\n  dep_value\n}\n\nexport fn answer() -> Int {\n  dep_value(1)\n}\n";

  const once = await runParallelProject(
    [depModule, { id: MAIN_ID, dependencies: [DEP_ID], dependencyOccurrences: [DEP_ID], source: mainSource }],
    { jobs: 2, execution },
  );
  const twice = await runParallelProject(
    [depModule, { id: MAIN_ID, dependencies: [DEP_ID], dependencyOccurrences: [DEP_ID, DEP_ID], source: mainSource }],
    { jobs: 2, execution },
  );

  assert.equal(once.outcomes.get(MAIN_ID).kind, "checked");
  assert.equal(twice.outcomes.get(MAIN_ID).kind, "checked");
  assert.notEqual(
    once.outcomes.get(MAIN_ID).artifact.fingerprint,
    twice.outcomes.get(MAIN_ID).artifact.fingerprint,
    "MAIN's fingerprint did not change when its dependencyOccurrences count changed -- the occurrence list is not reaching build_fingerprint's fold",
  );
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
