import assert from "node:assert/strict";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { checkProjectParallel, discoverProject } from "./parallel_project_driver.mjs";

const compilerWasm = process.env.VIBE_PARALLEL_COMPILER_WASM;
if (!compilerWasm) {
  throw new Error(
    "VIBE_PARALLEL_COMPILER_WASM must point to a current selfhost compiler",
  );
}

const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SAMPLE_DIR = join(ROOT_DIR, "scripts", "fixtures", "parallel_project_sample");
const LEAF = join(SAMPLE_DIR, "leaf.vibe");
const MID = join(SAMPLE_DIR, "mid.vibe");
const MAIN = join(SAMPLE_DIR, "main.vibe");
const MAIN_BROKEN = join(SAMPLE_DIR, "main_broken.vibe");

// #906. Everything up to this point (module_job_dir_test.sh,
// parallel_scheduler_selfhost.test.mjs) checks either the worker transport
// in isolation or synthetic in-memory module lists a test constructs by
// hand. This is the first proof that discovers a DAG from files that
// actually live on disk and drives it through the real worker pool.
test("discovery finds the diamond exactly once, not once per importer", async () => {
  const modules = await discoverProject(compilerWasm, [MAIN]);
  const byId = new Map(modules.map((m) => [m.id, m]));
  assert.equal(modules.length, 3, `expected {main, mid, leaf}, got ${modules.length}: ${[...byId.keys()]}`);
  assert.deepEqual(new Set(byId.get(MAIN).dependencies), new Set([LEAF, MID]));
  assert.deepEqual(byId.get(MID).dependencies, [LEAF]);
  assert.deepEqual(byId.get(LEAF).dependencies, []);
});

test("a real on-disk project checks clean through the worker pool", async () => {
  const result = await checkProjectParallel(compilerWasm, [MAIN], 2);
  assert.equal(result.outcomes.get(LEAF).kind, "checked");
  assert.equal(result.outcomes.get(MID).kind, "checked");
  assert.equal(result.outcomes.get(MAIN).kind, "checked");
});

// The two-hop proof: mid_value's signature only exists in the checker's
// environment because leaf.vibe's checked env reached mid.vibe first. If
// main_broken.vibe's wrong-argument-type call were caught by luck (e.g. an
// unresolved import falling back to a permissive Unknown type), it would
// still show up as SOME diagnostic -- so the message is asserted, not just
// the outcome kind.
test("a signature error two hops away surfaces through discovery + the worker pool", async () => {
  const result = await checkProjectParallel(compilerWasm, [MAIN_BROKEN], 2);
  assert.equal(result.outcomes.get(LEAF).kind, "checked");
  assert.equal(result.outcomes.get(MID).kind, "checked");
  const diagnosed = result.outcomes.get(MAIN_BROKEN);
  assert.equal(diagnosed.kind, "diagnosed");
  assert.match(diagnosed.diagnostics[0].message, /argument type mismatch for mid_value: expected Int, got String/);
});

test("real-project outcomes are identical for jobs=1/2/4", async () => {
  const modules = await discoverProject(compilerWasm, [MAIN]);
  const execution = { kind: "selfhost-check", compilerWasm };
  const { runParallelProject } = await import("./parallel_scheduler_prototype.mjs");
  const sequential = await runParallelProject(modules, { jobs: 1, execution });
  for (const jobs of [2, 4]) {
    const parallel = await runParallelProject(modules, { jobs, execution });
    assert.equal(parallel.output, sequential.output, `jobs=${jobs}`);
  }
});
