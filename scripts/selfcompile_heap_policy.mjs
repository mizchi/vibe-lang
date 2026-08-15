#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const POLICY_PATH = "bench/perf/selfcompile_heap_policy.json";
const BUDGET_DIR = "bench/perf/selfcompile_heap_budgets";
const POLICY_KEYS = [
  "budget_max_lifetime_days",
  "emergency_absolute_cap_bytes",
  "entry",
  "input",
  "schema",
  "tolerance_bytes",
];
const BUDGET_KEYS = [
  "base_commit",
  "expires_at",
  "feature",
  "id",
  "issue",
  "max_increase_bytes",
  "pull_request",
  "rationale",
  "schema",
];

export class HeapPolicyError extends Error {
  constructor(reason, details = {}) {
    super(reason);
    this.name = "HeapPolicyError";
    this.reason = reason;
    this.details = details;
  }
}

function fail(reason, details = {}) {
  throw new HeapPolicyError(reason, details);
}

function exactKeys(value, keys, reason) {
  if (value === null || Array.isArray(value) || typeof value !== "object") fail(reason);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, i) => key !== expected[i])) {
    fail(reason, { expected_fields: expected, actual_fields: actual });
  }
}

function safeInteger(value, { positive = false, nonnegative = false } = {}) {
  if (!Number.isSafeInteger(value)) return false;
  if (positive && value <= 0) return false;
  if (nonnegative && value < 0) return false;
  return true;
}

export function parsePolicy(text) {
  let policy;
  try {
    policy = JSON.parse(text);
  } catch {
    fail("malformed-policy");
  }
  exactKeys(policy, POLICY_KEYS, "malformed-policy");
  if (
    policy.schema !== 1 ||
    typeof policy.input !== "string" || policy.input.length === 0 || policy.input.startsWith("/") || policy.input.includes("..") ||
    policy.entry !== "__no_entry__" ||
    !safeInteger(policy.tolerance_bytes, { nonnegative: true }) ||
    !safeInteger(policy.emergency_absolute_cap_bytes, { positive: true }) ||
    !safeInteger(policy.budget_max_lifetime_days, { positive: true })
  ) fail("malformed-policy");
  return policy;
}

export function parseBudget(text, filename) {
  let budget;
  try {
    budget = JSON.parse(text);
  } catch {
    fail("malformed-budget", { filename });
  }
  exactKeys(budget, BUDGET_KEYS, "malformed-budget");
  if (
    budget.schema !== 1 ||
    typeof budget.id !== "string" || !/^[a-z0-9][a-z0-9-]*$/.test(budget.id) ||
    filename !== `${budget.id}.json` ||
    !safeInteger(budget.pull_request, { positive: true }) ||
    !/^[0-9a-f]{40}$/.test(budget.base_commit) ||
    !safeInteger(budget.max_increase_bytes, { positive: true }) ||
    typeof budget.expires_at !== "string" ||
    typeof budget.issue !== "string" || !/^https:\/\/github\.com\/.+\/issues\/[1-9][0-9]*$/.test(budget.issue) ||
    typeof budget.feature !== "string" || budget.feature.trim().length === 0 ||
    typeof budget.rationale !== "string" || budget.rationale.trim().length === 0
  ) fail("malformed-budget", { filename });
  const expires = Date.parse(budget.expires_at);
  if (!Number.isFinite(expires) || new Date(expires).toISOString() !== budget.expires_at) {
    fail("malformed-budget", { filename });
  }
  return { ...budget, expires_ms: expires };
}

export function evaluatePolicy({
  policy,
  baseHeap,
  currentHeap,
  budget = null,
  budgetChangeCount = 0,
  budgetHasInvalidChange = false,
  prNumber,
  baseCommit,
  baseCommitTimeMs,
  asOfMs,
}) {
  if (!safeInteger(baseHeap, { positive: true }) || !safeInteger(currentHeap, { positive: true })) {
    fail("malformed-kpi-output");
  }
  const delta = currentHeap - baseHeap;
  if (currentHeap > policy.emergency_absolute_cap_bytes) {
    fail("absolute-cap-exceeded", {
      base_heap_bytes: baseHeap,
      current_heap_bytes: currentHeap,
      delta_bytes: delta,
      emergency_absolute_cap_bytes: policy.emergency_absolute_cap_bytes,
    });
  }
  if (budgetHasInvalidChange) fail("budget-reused");
  if (budgetChangeCount > 1) fail("multiple-budgets");
  if (delta <= policy.tolerance_bytes) {
    if (budgetChangeCount !== 0) fail("budget-unnecessary", { delta_bytes: delta });
    return { decision: "pass", delta_bytes: delta, budget_id: null };
  }
  if (!budget || budgetChangeCount === 0) fail("budget-missing", { delta_bytes: delta });
  if (budget.pull_request !== prNumber) fail("budget-wrong-pr");
  if (budget.base_commit !== baseCommit) fail("budget-wrong-base");
  if (budget.expires_ms <= asOfMs) fail("budget-expired");
  const maxExpiry = baseCommitTimeMs + policy.budget_max_lifetime_days * 86_400_000;
  if (budget.expires_ms > maxExpiry) fail("budget-expired", { maximum_expires_at: new Date(maxExpiry).toISOString() });
  if (delta > budget.max_increase_bytes) {
    fail("budget-over-consumed", { delta_bytes: delta, max_increase_bytes: budget.max_increase_bytes });
  }
  return { decision: "pass", delta_bytes: delta, budget_id: budget.id };
}

function git(repo, args, options = {}) {
  try {
    return execFileSync("git", ["-C", repo, ...args], {
      encoding: options.encoding === null ? null : "utf8",
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    if (options.reason) fail(options.reason, { command: `git ${args[0]}` });
    throw error;
  }
}

function resolveCommit(repo, revision) {
  const oid = git(repo, ["rev-parse", "--verify", `${revision}^{commit}`], { reason: "missing-revision" }).trim();
  if (!/^[0-9a-f]{40}$/.test(oid)) fail("missing-revision", { revision });
  return oid;
}

function treeOf(repo, revision) {
  return git(repo, ["rev-parse", "--verify", `${revision}^{tree}`], { reason: "missing-revision" }).trim();
}

function synthesizeMergeTree(repo, base, head) {
  try {
    const output = git(repo, ["merge-tree", "--write-tree", base, head]).trim().split("\n")[0];
    if (!/^[0-9a-f]{40}$/.test(output)) fail("merge-conflict");
    return output;
  } catch (error) {
    if (error instanceof HeapPolicyError) throw error;
    fail("merge-conflict");
  }
}

function readTreeFile(repo, treeish, path, reason) {
  try {
    return git(repo, ["show", `${treeish}:${path}`], { encoding: null });
  } catch {
    fail(reason, { path });
  }
}

function treeFileExists(repo, treeish, path) {
  try {
    git(repo, ["cat-file", "-e", `${treeish}:${path}`]);
    return true;
  } catch {
    return false;
  }
}

function rejectReservedTreeEntries(repo, trees) {
  for (const tree of trees) {
    if (treeFileExists(repo, tree, "_build")) {
      fail("reserved-path-present", { tree, path: "_build" });
    }
  }
}

function archiveTree(repo, tree, destination) {
  mkdirSync(destination, { recursive: true });
  const archivePath = `${destination}.tar`;
  rmSync(archivePath, { force: true });
  try {
    execFileSync("git", ["-C", repo, "archive", "--format=tar", `--output=${archivePath}`, tree], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    execFileSync("tar", ["-xf", archivePath, "-C", destination], {
      stdio: ["ignore", "ignore", "pipe"],
    });
  } catch (error) {
    fail("materialize-failed", { stderr: String(error.stderr ?? "").slice(-4000) });
  } finally {
    rmSync(archivePath, { force: true });
  }
}

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--canonical-root") fail("invalid-arguments", { removed: "--canonical-root" });
    if (arg === "--synthesize-merge") options.synthesizeMerge = true;
    else if (arg.startsWith("--")) {
      const key = arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) fail("invalid-arguments", { argument: arg });
      options[key] = argv[++i];
    } else fail("invalid-arguments", { argument: arg });
  }
  return options;
}

function lstatIfPresent(path) {
  try {
    return lstatSync(path);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function verifyPhysicalDirectory(path, { requireOwner, reason }) {
  if (!isAbsolute(path)) fail(reason, { path });
  const resolved = resolve(path);
  const ancestry = [];
  let cursor = resolved;
  while (true) {
    ancestry.push(cursor);
    const parent = dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  for (const ancestor of ancestry.reverse()) {
    const info = lstatIfPresent(ancestor);
    if (!info) fail(reason, { missing: ancestor });
    if (info.isSymbolicLink() || !info.isDirectory()) fail(reason, { unsafe_ancestor: ancestor });
  }
  const info = lstatSync(resolved);
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  if (requireOwner && uid !== null && info.uid !== uid) fail(reason, { path: resolved, expected_uid: uid, actual_uid: info.uid });
  if (realpathSync(resolved) !== resolved) fail(reason, { path: resolved, realpath: realpathSync(resolved) });
  return resolved;
}

const activeWorkspaceLeases = new Set();

function verifyWorkspaceLease(lease) {
  if (!activeWorkspaceLeases.has(lease)) fail("unsafe-workspace-lease", { lease });
  const info = lstatSync(lease);
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  if (
    info.isSymbolicLink() || !info.isDirectory() ||
    (uid !== null && info.uid !== uid) ||
    (info.mode & 0o777) !== 0o700 ||
    realpathSync(lease) !== lease
  ) fail("unsafe-workspace-lease", { lease });
}

function createWorkspaceLease() {
  const ci = process.env.GITHUB_ACTIONS === "true";
  let tempBase;
  if (ci) {
    if (!process.env.RUNNER_TEMP) fail("unsafe-runner-temp");
    tempBase = verifyPhysicalDirectory(process.env.RUNNER_TEMP, { requireOwner: true, reason: "unsafe-runner-temp" });
  } else {
    tempBase = verifyPhysicalDirectory(realpathSync(os.tmpdir()), { requireOwner: false, reason: "unsafe-local-temp" });
  }
  const lease = mkdtempSync(join(tempBase, "vibe-selfcompile-policy-"));
  chmodSync(lease, 0o700);
  activeWorkspaceLeases.add(lease);
  try {
    verifyWorkspaceLease(lease);
  } catch (error) {
    activeWorkspaceLeases.delete(lease);
    rmSync(lease, { recursive: true, force: true });
    throw error;
  }
  return lease;
}

function resetWorkspaceRoot(lease) {
  verifyWorkspaceLease(lease);
  const root = join(lease, "root");
  const info = lstatIfPresent(root);
  if (info?.isSymbolicLink()) fail("unsafe-workspace-lease", { symlink: root });
  if (info && !info.isDirectory()) fail("unsafe-workspace-lease", { non_directory: root });
  rmSync(root, { recursive: true, force: true });
  mkdirSync(root, { mode: 0o700 });
  return root;
}

function removeWorkspaceLease(lease) {
  verifyWorkspaceLease(lease);
  rmSync(lease, { recursive: true, force: true });
  activeWorkspaceLeases.delete(lease);
}

function pinnedInputPathSafe(root, input) {
  const rootReal = realpathSync(root);
  if (rootReal !== root) fail("unsafe-pinned-input", { root, root_realpath: rootReal });
  const inputPath = join(root, input);
  const inputRelative = relative(root, inputPath);
  if (inputRelative === "" || inputRelative === ".." || inputRelative.startsWith(".." + sep) || isAbsolute(inputRelative)) {
    fail("unsafe-pinned-input", { input });
  }
  const parts = inputRelative.split(sep);
  let cursor = root;
  for (let i = 0; i < parts.length; i += 1) {
    cursor = join(cursor, parts[i]);
    const info = lstatIfPresent(cursor);
    const isFinal = i === parts.length - 1;
    if (!info) {
      if (!isFinal) fail("unsafe-pinned-input", { missing_ancestor: cursor });
      break;
    }
    if (info.isSymbolicLink()) fail("unsafe-pinned-input", { symlink: cursor });
    if (!isFinal && !info.isDirectory()) fail("unsafe-pinned-input", { non_directory_ancestor: cursor });
    if (isFinal && !info.isFile()) fail("unsafe-pinned-input", { non_file: cursor });
  }
  const parent = dirname(inputPath);
  const parentReal = realpathSync(parent);
  const parentRelative = relative(rootReal, parentReal);
  if (parentRelative === ".." || parentRelative.startsWith(".." + sep) || isAbsolute(parentRelative)) {
    fail("unsafe-pinned-input", { input_parent_realpath: parentReal });
  }
  return inputPath;
}

function overwritePinnedInput(inputPath, inputBlob) {
  let fd;
  try {
    fd = openSync(inputPath, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
    writeFileSync(fd, inputBlob);
  } catch (error) {
    fail("unsafe-pinned-input", { path: inputPath, code: error.code });
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function cleanEnvironment(root) {
  const envRoot = join(root, "_build", "selfcompile-policy", "environment");
  const home = join(envRoot, "home");
  const tmp = join(envRoot, "tmp");
  const vibeHome = join(envRoot, "vibe-home");
  mkdirSync(home, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  mkdirSync(vibeHome, { recursive: true });
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: home,
    TMPDIR: tmp,
    VIBE_HOME: vibeHome,
    LC_ALL: "C",
    LANG: "C",
    TZ: "UTC",
    SOURCE_DATE_EPOCH: "0",
    VIBE_RC: "0",
    VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
  };
}

function runChecked(command, args, cwd, env, reason, capture = false) {
  try {
    return execFileSync(command, args, {
      cwd,
      env,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", capture ? "pipe" : "ignore", "pipe"],
    });
  } catch (error) {
    fail(reason, { command: `${command} ${args.join(" ")}`, stderr: String(error.stderr ?? "").slice(-4000) });
  }
}

function parseMeasurement(output) {
  const lines = output.split(/\r?\n/).filter(line => line.startsWith("[selfcompile-kpi] input="));
  if (lines.length !== 1) fail("malformed-kpi-output", { kpi_lines: lines.length });
  const match = lines[0].match(/\bheap_ptr_bytes=([0-9]+)\b/);
  if (!match) fail("malformed-kpi-output");
  const value = Number(match[1]);
  if (!safeInteger(value, { positive: true })) fail("malformed-kpi-output");
  return value;
}

async function measureTreeOnce({ repo, tree, label, lease, inputBlob, policy, testDriver }) {
  const root = resetWorkspaceRoot(lease);
  await archiveTree(repo, tree, root);
  // The merge tree is untrusted. Validate before writing the pinned base input
  // or executing any extracted script; tracked symlinks must not escape root.
  const inputPath = pinnedInputPathSafe(root, policy.input);
  overwritePinnedInput(inputPath, inputBlob);
  const env = cleanEnvironment(root);
  const generationDir = join(root, "_build", "selfcompile-policy", "generation");
  const stage2 = join(generationDir, "stage2.wasm");
  const workDir = join(root, "_build", "selfcompile-policy", "kpi-work");

  if (testDriver) {
    if (process.env.VIBE_HEAP_POLICY_TEST_MODE !== "1") fail("test-driver-forbidden");
    runChecked(process.execPath, [testDriver, "build"], root, {
      ...env,
      POLICY_REVISION: label,
      POLICY_CANONICAL_ROOT: root,
      POLICY_STAGE2: stage2,
      POLICY_INPUT: inputPath,
      POLICY_WORK_DIR: workDir,
    }, "build-failed");
  } else {
    runChecked("bash", ["scripts/ensure_generated.sh", "--force"], root, env, "generated-failed");
    const expected = runChecked("bash", ["scripts/ensure_generated.sh", "--print-fingerprint"], root, env, "generated-failed", true).trim();
    let stamp = "";
    try { stamp = readFileSync(join(root, "lib/@vibe/compiler/.generated.stamp"), "utf8").trim(); } catch {}
    if (stamp !== expected) fail("generated-fingerprint-mismatch", { expected, actual: stamp });
    runChecked("bash", ["scripts/generations.sh", "build", "--out-dir", generationDir, "--skip-run-validation"], root, env, "build-failed");
  }

  let stage2Sha256;
  try {
    stage2Sha256 = createHash("sha256").update(readFileSync(stage2)).digest("hex");
  } catch {
    fail("build-failed", { missing: stage2 });
  }

  const trials = [];
  for (let trial = 1; trial <= 2; trial += 1) {
    let output;
    if (testDriver) {
      output = runChecked(process.execPath, [testDriver, "measure", String(trial)], root, {
        ...env,
        POLICY_REVISION: label,
        POLICY_CANONICAL_ROOT: root,
        POLICY_STAGE2: stage2,
        POLICY_INPUT: inputPath,
        POLICY_WORK_DIR: workDir,
      }, "build-failed", true);
    } else {
      output = runChecked("bash", ["scripts/selfcompile_kpi.sh", stage2, policy.input], root, {
        ...env,
        VIBE_KPI_WORK_DIR: workDir,
        VIBE_KPI_ALLOWED_WORK_ROOT: join(root, "_build"),
      }, "build-failed", true);
    }
    trials.push(parseMeasurement(output));
  }
  if (trials[0] !== trials[1]) fail("nondeterministic-heap", { revision: label, trials });
  return {
    heap_bytes: trials[0],
    trials,
    stage2_sha256: stage2Sha256,
    normalized_paths: {
      canonical_root: root,
      input: policy.input,
      stage2: "_build/selfcompile-policy/generation/stage2.wasm",
      output: "_build/selfcompile-policy/kpi-work/out.wasm",
      cache: "_build/selfcompile-policy/kpi-work/cache",
      home: "_build/selfcompile-policy/environment/home",
      tmpdir: "_build/selfcompile-policy/environment/tmp",
      vibe_home: "_build/selfcompile-policy/environment/vibe-home",
    },
  };
}

async function measureTree(args) {
  return await measureTreeOnce(args);
}

function budgetChanges(repo, base, currentTree) {
  let output = "";
  try {
    output = git(repo, ["diff", "--no-renames", "--name-status", "-z", base, currentTree, "--", BUDGET_DIR]);
  } catch {
    fail("budget-diff-failed");
  }
  const parts = output.split("\0").filter(Boolean);
  const added = [];
  let invalid = false;
  for (let i = 0; i < parts.length; i += 2) {
    const status = parts[i];
    const path = parts[i + 1];
    if (!path) fail("budget-diff-failed");
    if (status === "A") added.push(path);
    else invalid = true;
  }
  return { added, invalid };
}

async function runControllerWithLease(options, lease) {
  const repo = resolve(options.repo ?? ".");
  const root = join(lease, "root");
  if (!options.base || !options.head || !options.prNumber) fail("invalid-arguments");
  const prNumber = Number(options.prNumber);
  if (!safeInteger(prNumber, { positive: true })) fail("invalid-arguments");
  const base = resolveCommit(repo, options.base);
  const head = resolveCommit(repo, options.head);
  const mergeTree = synthesizeMergeTree(repo, base, head);
  let currentTree = mergeTree;
  let current = null;
  if (options.current) {
    current = resolveCommit(repo, options.current);
    try {
      git(repo, ["merge-base", "--is-ancestor", base, current]);
    } catch {
      fail("stale-or-wrong-merge-result");
    }
    const actualTree = treeOf(repo, current);
    if (actualTree !== mergeTree) fail("stale-or-wrong-merge-result", { expected_tree: mergeTree, actual_tree: actualTree });
    currentTree = actualTree;
  } else if (!options.synthesizeMerge) {
    fail("invalid-arguments", { missing: "--current or --synthesize-merge" });
  }
  const baseTree = treeOf(repo, base);
  rejectReservedTreeEntries(repo, [baseTree, currentTree]);

  const policyText = readTreeFile(repo, base, POLICY_PATH, "malformed-policy").toString("utf8");
  const policy = parsePolicy(policyText);
  if (!treeFileExists(repo, currentTree, POLICY_PATH)) fail("malformed-policy", { path: POLICY_PATH });
  const currentPolicyText = readTreeFile(repo, currentTree, POLICY_PATH, "malformed-policy").toString("utf8");
  parsePolicy(currentPolicyText); // Future/base policy must remain usable even though it cannot authorize this run.
  const policyChanged = currentPolicyText !== policyText;
  const inputBlob = readTreeFile(repo, base, policy.input, "benchmark-input-missing");
  const changes = budgetChanges(repo, base, currentTree);
  let budget = null;
  if (changes.added.length === 1) {
    const path = changes.added[0];
    if (dirname(path) !== BUDGET_DIR) fail("malformed-budget", { path });
    budget = parseBudget(readTreeFile(repo, currentTree, path, "malformed-budget").toString("utf8"), path.slice(BUDGET_DIR.length + 1));
  }

  const baseCommitTime = Number(git(repo, ["show", "-s", "--format=%ct", base]).trim()) * 1000;
  const asOfMs = options.asOf ? Date.parse(options.asOf) : Date.now();
  if (!Number.isFinite(asOfMs)) fail("invalid-arguments", { argument: "--as-of" });
  const baseResult = await measureTree({ repo, tree: baseTree, label: "base", lease, inputBlob, policy, testDriver: options.testDriver });
  const currentResult = await measureTree({ repo, tree: currentTree, label: "current", lease, inputBlob, policy, testDriver: options.testDriver });
  if (baseTree === currentTree) {
    if (baseResult.stage2_sha256 !== currentResult.stage2_sha256) {
      fail("nondeterministic-build", {
        base_stage2_sha256: baseResult.stage2_sha256,
        current_stage2_sha256: currentResult.stage2_sha256,
      });
    }
    if (baseResult.heap_bytes !== currentResult.heap_bytes) {
      fail("nondeterministic-heap", {
        revision: "identical-tree-reconstruction",
        trials: [...baseResult.trials, ...currentResult.trials],
      });
    }
  }
  const evaluation = evaluatePolicy({
    policy,
    baseHeap: baseResult.heap_bytes,
    currentHeap: currentResult.heap_bytes,
    budget,
    budgetChangeCount: changes.added.length,
    budgetHasInvalidChange: changes.invalid,
    prNumber,
    baseCommit: base,
    baseCommitTimeMs: baseCommitTime,
    asOfMs,
  });
  return {
    schema: 1,
    decision: evaluation.decision,
    base_commit: base,
    head_commit: head,
    current_commit: current,
    measured_tree: currentTree,
    policy_source_commit: base,
    policy_change_effective_this_run: false,
    policy_changed: policyChanged,
    base_heap_bytes: baseResult.heap_bytes,
    current_heap_bytes: currentResult.heap_bytes,
    delta_bytes: evaluation.delta_bytes,
    tolerance_bytes: policy.tolerance_bytes,
    emergency_absolute_cap_bytes: policy.emergency_absolute_cap_bytes,
    budget_id: evaluation.budget_id,
    trials: { base: baseResult.trials, current: currentResult.trials },
    stage2_sha256: { base: baseResult.stage2_sha256, current: currentResult.stage2_sha256 },
    normalized_paths: baseResult.normalized_paths,
    benchmark_input_source_commit: base,
  };
}

export async function runController(options) {
  if (options.canonicalRoot !== undefined) fail("invalid-arguments", { removed: "--canonical-root" });
  const lease = createWorkspaceLease();
  try {
    return await runControllerWithLease(options, lease);
  } finally {
    removeWorkspaceLease(lease);
  }
}

async function main() {
  try {
    const result = await runController(parseArgs(process.argv.slice(2)));
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    const reason = error instanceof HeapPolicyError ? error.reason : "internal-error";
    const details = error instanceof HeapPolicyError ? error.details : { message: String(error?.stack ?? error) };
    process.stderr.write(`[heap-policy] FAIL reason=${reason}\n`);
    process.stdout.write(`${JSON.stringify({ schema: 1, decision: "fail", reason, ...details })}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
