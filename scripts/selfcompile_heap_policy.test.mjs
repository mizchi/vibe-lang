import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import {
  HeapPolicyError,
  evaluatePolicy,
  parseBudget,
  parsePolicy,
  runController,
} from "./selfcompile_heap_policy.mjs";

const policy = parsePolicy(JSON.stringify({
  schema: 1,
  input: "lib/@vibe/compiler/tests/codegen_lexer_test.vibe",
  entry: "__no_entry__",
  tolerance_bytes: 0,
  emergency_absolute_cap_bytes: 1_105_822_775,
  budget_max_lifetime_days: 30,
}));
const baseCommit = "a".repeat(40);
const baseTime = Date.parse("2026-08-01T00:00:00.000Z");
const asOf = Date.parse("2026-08-02T00:00:00.000Z");

function budget(overrides = {}) {
  const raw = {
    schema: 1,
    id: "pr-1801-feature",
    pull_request: 1801,
    base_commit: baseCommit,
    max_increase_bytes: 8_000_000,
    expires_at: "2026-08-10T00:00:00.000Z",
    issue: "https://github.com/mizchi/vibe-lang/issues/1800",
    feature: "feature",
    rationale: "measured and reviewed growth",
    ...overrides,
  };
  return parseBudget(JSON.stringify(raw), `${raw.id}.json`);
}

function evaluate(overrides = {}) {
  return evaluatePolicy({
    policy,
    baseHeap: 1_000_000_000,
    currentHeap: 1_000_000_000,
    budget: null,
    budgetChangeCount: 0,
    budgetHasInvalidChange: false,
    prNumber: 1801,
    baseCommit,
    baseCommitTimeMs: baseTime,
    asOfMs: asOf,
    ...overrides,
  });
}

function reason(fn, expected) {
  assert.throws(fn, error => error instanceof HeapPolicyError && error.reason === expected);
}

test("equal and improvements pass without creating authority", () => {
  assert.equal(evaluate().delta_bytes, 0);
  assert.equal(evaluate({ currentHeap: 900_000_000 }).delta_bytes, -100_000_000);
  // The improved current becomes the next comparison's base: one byte back is red.
  reason(() => evaluate({ baseHeap: 900_000_000, currentHeap: 900_000_001 }), "budget-missing");
});

test("one byte growth is fail-closed and a valid one-shot budget is bounded", () => {
  reason(() => evaluate({ currentHeap: 1_000_000_001 }), "budget-missing");
  assert.equal(evaluate({
    currentHeap: 1_000_000_001,
    budget: budget(),
    budgetChangeCount: 1,
  }).budget_id, "pr-1801-feature");
  reason(() => evaluate({
    currentHeap: 1_009_000_000,
    budget: budget(),
    budgetChangeCount: 1,
  }), "budget-over-consumed");
});

test("budget provenance, expiry, reuse, multiplicity, and necessity are enforced", () => {
  const growing = { currentHeap: 1_000_000_001, budgetChangeCount: 1 };
  reason(() => evaluate({ ...growing, budget: budget({ pull_request: 1802 }) }), "budget-wrong-pr");
  reason(() => evaluate({ ...growing, budget: budget({ base_commit: "b".repeat(40) }) }), "budget-wrong-base");
  reason(() => evaluate({ ...growing, budget: budget({ expires_at: "2026-08-01T00:00:00.000Z" }) }), "budget-expired");
  reason(() => evaluate({ ...growing, budget: budget({ expires_at: "2026-09-10T00:00:00.000Z" }) }), "budget-expired");
  reason(() => evaluate({ ...growing, budget: budget(), budgetHasInvalidChange: true }), "budget-reused");
  reason(() => evaluate({ ...growing, budget: budget(), budgetChangeCount: 2 }), "multiple-budgets");
  reason(() => evaluate({ budget: budget(), budgetChangeCount: 1 }), "budget-unnecessary");
});

test("the emergency cap cannot be overridden by a budget", () => {
  reason(() => evaluate({
    baseHeap: 1_105_000_000,
    currentHeap: 1_105_822_776,
    budget: budget({ max_increase_bytes: 100_000_000 }),
    budgetChangeCount: 1,
  }), "absolute-cap-exceeded");
});

test("policy and budget schemas reject unknown, unsafe, and forged fields", () => {
  reason(() => parsePolicy(JSON.stringify({ ...policy, extra: true })), "malformed-policy");
  reason(() => parseBudget(JSON.stringify({ ...budget(), id: "../escape" }), "../escape.json"), "malformed-budget");
  const raw = { ...budget() };
  delete raw.expires_ms;
  raw.extra = true;
  reason(() => parseBudget(JSON.stringify(raw), `${raw.id}.json`), "malformed-budget");
});

function command(repo, args, env = {}) {
  return execFileSync("git", args, { cwd: repo, encoding: "utf8", env: { ...process.env, ...env } }).trim();
}

function commitAll(repo, message, date) {
  command(repo, ["add", "."]);
  command(repo, ["commit", "-m", message], {
    GIT_AUTHOR_DATE: date,
    GIT_COMMITTER_DATE: date,
  });
  return command(repo, ["rev-parse", "HEAD"]);
}

function makeRepository() {
  const outer = mkdtempSync(join(os.tmpdir(), "heap-policy-test-"));
  const repo = join(outer, "repo");
  mkdirSync(repo);
  command(repo, ["init", "-q"]);
  command(repo, ["config", "user.email", "test@example.invalid"]);
  command(repo, ["config", "user.name", "Heap Policy Test"]);
  const input = "lib/@vibe/compiler/tests/codegen_lexer_test.vibe";
  mkdirSync(join(repo, "bench/perf"), { recursive: true });
  mkdirSync(join(repo, "lib/@vibe/compiler/tests"), { recursive: true });
  writeFileSync(join(repo, "bench/perf/selfcompile_heap_policy.json"), JSON.stringify(policy, null, 2) + "\n");
  writeFileSync(join(repo, input), "base benchmark input\n");
  writeFileSync(join(repo, "heap.txt"), "1000\n");
  const initial = commitAll(repo, "initial", "2026-08-01T00:00:00Z");
  return { outer, repo, input, initial };
}

function makeDriver(outer) {
  const path = join(outer, "driver.mjs");
  writeFileSync(path, `
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
const [phase, trial] = process.argv.slice(2);
const root = process.env.POLICY_CANONICAL_ROOT;
const log = join(dirname(root), "driver-log.jsonl");
appendFileSync(log, JSON.stringify({
  phase, trial, revision: process.env.POLICY_REVISION, root,
  stage2: process.env.POLICY_STAGE2, input: process.env.POLICY_INPUT,
  work: process.env.POLICY_WORK_DIR, home: process.env.HOME,
  tmp: process.env.TMPDIR, vibeHome: process.env.VIBE_HOME,
  inputText: readFileSync(process.env.POLICY_INPUT, "utf8"),
}) + "\\n");
if (phase === "build") {
  if (process.env.POLICY_REVISION === "current" && existsSync(join(root, ".base-only"))) process.exit(9);
  if (process.env.POLICY_REVISION === "base") writeFileSync(join(root, ".base-only"), "must be deleted");
  mkdirSync(dirname(process.env.POLICY_STAGE2), { recursive: true });
  const buildSuffix = existsSync(join(root, "build-drift.txt")) ? process.env.POLICY_REVISION : "";
  writeFileSync(process.env.POLICY_STAGE2, "mock wasm" + buildSuffix);
} else {
  let heap = Number(readFileSync(join(root, "heap.txt"), "utf8"));
  if (existsSync(join(root, "nondeterministic.txt")) && trial === "2") heap += 1;
  if (existsSync(join(root, "reconstruction-drift.txt")) && process.env.POLICY_REVISION === "current") heap += 1;
  process.stdout.write(\`[selfcompile-kpi] input=x wall_ms=1 heap_ptr_bytes=\${heap} mem_pages=1\\n\`);
}
`);
  return path;
}

async function controller(options) {
  const old = process.env.VIBE_HEAP_POLICY_TEST_MODE;
  process.env.VIBE_HEAP_POLICY_TEST_MODE = "1";
  try { return await runController(options); }
  finally {
    if (old === undefined) delete process.env.VIBE_HEAP_POLICY_TEST_MODE;
    else process.env.VIBE_HEAP_POLICY_TEST_MODE = old;
  }
}

test("controller synthesizes latest-base merge, pins input, reuses exact paths, and isolates revisions", async () => {
  const fixture = makeRepository();
  const driver = makeDriver(fixture.outer);
  command(fixture.repo, ["checkout", "-q", "-b", "feature", fixture.initial]);
  writeFileSync(join(fixture.repo, fixture.input), "head tried to replace benchmark\n");
  writeFileSync(join(fixture.repo, "feature.txt"), "feature\n");
  const head = commitAll(fixture.repo, "feature", "2026-08-01T01:00:00Z");
  command(fixture.repo, ["checkout", "-q", "main"]);
  writeFileSync(join(fixture.repo, "main.txt"), "latest base\n");
  const base = commitAll(fixture.repo, "main advance", "2026-08-01T02:00:00Z");
  const root = join(fixture.outer, "vibe-selfcompile-policy", "root");
  const result = await controller({
    repo: fixture.repo, base, head, synthesizeMerge: true, prNumber: "1801",
    asOf: "2026-08-02T00:00:00.000Z", canonicalRoot: root, testDriver: driver,
  });
  assert.equal(result.decision, "pass");
  assert.equal(result.base_heap_bytes, 1000);
  assert.deepEqual(result.trials, { base: [1000, 1000], current: [1000, 1000] });
  const log = readFileSync(join(dirname(root), "driver-log.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(log.length, 6);
  assert.ok(log.every(row => row.root === root));
  assert.ok(log.every(row => row.inputText === "base benchmark input\n"));
  for (const key of ["stage2", "input", "work", "home", "tmp", "vibeHome"]) {
    assert.equal(new Set(log.map(row => row[key])).size, 1, `${key} must be identical`);
  }
});

test("controller consumes one new base-bound budget and ignores a permissive head policy", async () => {
  const fixture = makeRepository();
  const driver = makeDriver(fixture.outer);
  writeFileSync(join(fixture.repo, "heap.txt"), "1001\n");
  mkdirSync(join(fixture.repo, "bench/perf/selfcompile_heap_budgets"), { recursive: true });
  const record = {
    schema: 1,
    id: "pr-1801-integration",
    pull_request: 1801,
    base_commit: fixture.initial,
    max_increase_bytes: 1,
    expires_at: "2026-08-10T00:00:00.000Z",
    issue: "https://github.com/mizchi/vibe-lang/issues/1800",
    feature: "integration fixture",
    rationale: "exercise one-shot diff authority",
  };
  writeFileSync(join(fixture.repo, "bench/perf/selfcompile_heap_budgets/pr-1801-integration.json"), JSON.stringify(record, null, 2));
  const headPolicy = { ...policy, tolerance_bytes: 999_999_999 };
  writeFileSync(join(fixture.repo, "bench/perf/selfcompile_heap_policy.json"), JSON.stringify(headPolicy, null, 2));
  const head = commitAll(fixture.repo, "budgeted growth", "2026-08-01T01:00:00Z");
  const root = join(fixture.outer, "vibe-selfcompile-policy", "root");
  const result = await controller({
    repo: fixture.repo, base: fixture.initial, head, synthesizeMerge: true,
    prNumber: "1801", asOf: "2026-08-02T00:00:00.000Z",
    canonicalRoot: root, testDriver: driver,
  });
  assert.equal(result.delta_bytes, 1);
  assert.equal(result.budget_id, record.id);
  assert.equal(result.policy_changed, true);
  assert.equal(result.tolerance_bytes, 0);
  assert.equal(result.policy_source_commit, fixture.initial);
});

test("controller rejects merge conflicts", async () => {
  const fixture = makeRepository();
  const driver = makeDriver(fixture.outer);
  command(fixture.repo, ["checkout", "-q", "-b", "feature", fixture.initial]);
  writeFileSync(join(fixture.repo, "heap.txt"), "1001\n");
  const head = commitAll(fixture.repo, "feature heap", "2026-08-01T01:00:00Z");
  command(fixture.repo, ["checkout", "-q", "main"]);
  writeFileSync(join(fixture.repo, "heap.txt"), "999\n");
  const base = commitAll(fixture.repo, "base heap", "2026-08-01T02:00:00Z");
  const root = join(fixture.outer, "vibe-selfcompile-policy", "root");
  await assert.rejects(() => controller({
    repo: fixture.repo, base, head, synthesizeMerge: true,
    prNumber: "1801", canonicalRoot: root, testDriver: driver,
  }), error => error.reason === "merge-conflict");
});

test("identical trees reject stable cross-reconstruction drift", async () => {
  for (const [marker, expected] of [["reconstruction-drift.txt", "nondeterministic-heap"], ["build-drift.txt", "nondeterministic-build"]]) {
    const fixture = makeRepository();
    const driver = makeDriver(fixture.outer);
    writeFileSync(join(fixture.repo, marker), "yes\n");
    const same = commitAll(fixture.repo, marker, "2026-08-01T01:00:00Z");
    const root = join(fixture.outer, "vibe-selfcompile-policy", "root");
    await assert.rejects(() => controller({
      repo: fixture.repo, base: same, head: same, synthesizeMerge: true,
      prNumber: "1801", canonicalRoot: root, testDriver: driver,
    }), error => error.reason === expected);
  }
});

test("controller rejects nondeterminism, missing revisions, and wrong merge results", async () => {
  const fixture = makeRepository();
  const driver = makeDriver(fixture.outer);
  writeFileSync(join(fixture.repo, "nondeterministic.txt"), "yes\n");
  const head = commitAll(fixture.repo, "nondeterministic", "2026-08-01T01:00:00Z");
  const root = join(fixture.outer, "vibe-selfcompile-policy", "root");
  await assert.rejects(() => controller({
    repo: fixture.repo, base: fixture.initial, head, synthesizeMerge: true,
    prNumber: "1801", canonicalRoot: root, testDriver: driver,
  }), error => error.reason === "nondeterministic-heap");
  await assert.rejects(() => controller({
    repo: fixture.repo, base: "missing", head, synthesizeMerge: true,
    prNumber: "1801", canonicalRoot: root, testDriver: driver,
  }), error => error.reason === "missing-revision");
  await assert.rejects(() => controller({
    repo: fixture.repo, base: fixture.initial, head, current: fixture.initial,
    prNumber: "1801", canonicalRoot: root, testDriver: driver,
  }), error => error.reason === "stale-or-wrong-merge-result");
});
