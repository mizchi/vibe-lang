import assert from "node:assert/strict";
import test from "node:test";

import {
  runParallelProject,
  validateParallelTrace,
} from "./parallel_scheduler_prototype.mjs";

function diamondProject(overrides = {}) {
  return [
    { id: "base", dependencies: [], source: "base", workMs: 2 },
    {
      id: "frontend",
      dependencies: ["base"],
      source: "frontend",
      workMs: 35,
    },
    {
      id: "backend",
      dependencies: ["base"],
      source: "backend",
      workMs: 5,
    },
    {
      id: "app",
      dependencies: ["frontend", "backend"],
      source: "app",
      workMs: 1,
    },
  ].map((module) => ({ ...module, ...overrides[module.id] }));
}

test("real workers preserve canonical output for jobs=1/2/4", async () => {
  const project = diamondProject();
  const sequential = await runParallelProject(project, { jobs: 1 });
  const twoWorkers = await runParallelProject(project, { jobs: 2 });
  const fourWorkers = await runParallelProject(project, { jobs: 4 });

  assert.equal(twoWorkers.output, sequential.output);
  assert.equal(fourWorkers.output, sequential.output);
  const validation = validateParallelTrace(project, twoWorkers.trace, 2);
  assert.equal(validation.complete, true);
  assert.equal(validation.maxRunning, 2);
  assert.equal(
    validation.projectedAsyncEvents.filter((event) => event.kind === "dispatch").length,
    project.length,
  );

  const frontendClaim = twoWorkers.trace.findIndex(
    (event) => event.kind === "claim" && event.task === "frontend",
  );
  const backendClaim = twoWorkers.trace.findIndex(
    (event) => event.kind === "claim" && event.task === "backend",
  );
  const firstIndependentRelease = twoWorkers.trace.findIndex(
    (event) =>
      event.kind === "releaseComplete" &&
      (event.task === "frontend" || event.task === "backend"),
  );
  assert.ok(frontendClaim >= 0);
  assert.ok(backendClaim >= 0);
  assert.ok(frontendClaim < firstIndependentRelease);
  assert.ok(backendClaim < firstIndependentRelease);
});

test("workers start only from terminal dependency snapshots", async () => {
  const project = diamondProject();
  const run = await runParallelProject(project, { jobs: 4 });

  const publishedAt = new Map();
  for (const [index, event] of run.trace.entries()) {
    if (event.kind === "publish") publishedAt.set(event.task, index);
    if (event.kind !== "claim") continue;
    const module = project.find((candidate) => candidate.id === event.task);
    for (const dependency of module.dependencies) {
      assert.ok(publishedAt.get(dependency) < index);
    }
  }
});

test("diagnostics are values and remain canonically ordered", async () => {
  const project = diamondProject({
    frontend: {
      source: "diagnostic:E_FRONT:frontend failed",
      workMs: 30,
    },
    backend: {
      source: "diagnostic:E_BACK:backend failed",
      workMs: 1,
    },
  });

  const one = await runParallelProject(project, { jobs: 1 });
  const four = await runParallelProject(project, { jobs: 4 });

  assert.equal(four.output, one.output);
  const parsed = JSON.parse(four.output);
  assert.deepEqual(
    parsed.diagnostics.map((diagnostic) => diagnostic.module),
    ["app", "backend", "frontend"],
  );
  assert.deepEqual(
    parsed.diagnostics.map((diagnostic) => diagnostic.code),
    ["E_DEPENDENCY", "E_BACK", "E_FRONT"],
  );
});

test("trace validation rejects a task claimed by two workers", () => {
  const project = [{ id: "only", dependencies: [], source: "only" }];
  const invalidTrace = [
    { seq: 0, kind: "ready", task: "only" },
    { seq: 1, kind: "claim", worker: 0, task: "only" },
    { seq: 2, kind: "claim", worker: 1, task: "only" },
  ];

  assert.throws(
    () => validateParallelTrace(project, invalidTrace, 2),
    /task "only" is not ready/,
  );
});

test("an unexpected worker crash fails the instance and cleans up workers", async () => {
  const crashing = diamondProject({
    backend: { source: "backend", crash: true, workMs: 1 },
  });

  await assert.rejects(
    runParallelProject(crashing, { jobs: 2 }),
    /worker task "backend" failed/,
  );

  const recovered = await runParallelProject(diamondProject(), { jobs: 2 });
  assert.equal(validateParallelTrace(diamondProject(), recovered.trace, 2).complete, true);
});

test("worker count is host policy and must be positive", async () => {
  await assert.rejects(
    runParallelProject(diamondProject(), { jobs: 0 }),
    /jobs must be an integer greater than or equal to 1/,
  );
});

test("execution strategy is an explicit runtime contract", async () => {
  await assert.rejects(
    runParallelProject(diamondProject(), {
      jobs: 1,
      execution: { kind: "shared-everything" },
    }),
    /unknown parallel execution kind/,
  );
  await assert.rejects(
    runParallelProject(diamondProject(), {
      jobs: 1,
      execution: { kind: "selfhost-check" },
    }),
    /selfhost-check requires compilerWasm/,
  );
});
