#!/usr/bin/env bash
# #906 Phase 2 (real-build wiring): end-to-end proof that
# scripts/parallel_frontend_warm.mjs's cache pre-warm never changes what a
# real compile produces, and that it actually warms the persistent cache
# rather than silently no-op'ing.
#
# Private frontend checks use the Node runner. The public relative-path
# build --jobs checks use the native runner and compiler-matched TaskGroup
# images; build those images when the caller has not supplied them.
#
# Usage: bash scripts/test_parallel_frontend_warm.sh [stage2.wasm]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

COMPILER_WASM="${1:-}"
if [ -z "$COMPILER_WASM" ]; then
  short_sha="$(git rev-parse --short HEAD)"
  compiler_inputs_dirty="$(
    git status --porcelain -- \
      lib/@vibe/compiler \
      lib/@vibe/cli \
      bootstrap/seed.json \
      scripts/generate_bundle.sh \
      scripts/generations.sh
  )"
  if [ -z "$compiler_inputs_dirty" ]; then
    COMPILER_WASM="$(
      find _build/selfhost/generations \
        -path "*_${short_sha}/stage2.wasm" -type f -print 2>/dev/null \
        | head -n 1
    )"
  fi
fi
if [ -z "$COMPILER_WASM" ] || [ ! -s "$COMPILER_WASM" ]; then
  out_dir="$PROJECT_ROOT/_build/parallel_frontend_warm_selfhost"
  echo "[jobs-warm] building current stage2 compiler" >&2
  bash scripts/generations.sh build --out-dir "$out_dir" >/dev/null
  COMPILER_WASM="$out_dir/stage2.wasm"
fi
[ -s "$COMPILER_WASM" ] || { echo "[jobs-warm] compiler not found: $COMPILER_WASM" >&2; exit 1; }
COMPILER_WASM="$(cd "$(dirname "$COMPILER_WASM")" && pwd)/$(basename "$COMPILER_WASM")"
if [ -z "${VIBE_TASKGROUP_ARTIFACT_DIR:-}" ]; then
  mkdir -p "$PROJECT_ROOT/_build"
  VIBE_TASKGROUP_ARTIFACT_DIR="$(mktemp -d "$PROJECT_ROOT/_build/parallel-public-images-XXXXXX")"
  bash "$PROJECT_ROOT/scripts/build_taskgroup_checker.sh" "$COMPILER_WASM" "$VIBE_TASKGROUP_ARTIFACT_DIR" >/dev/null
  export VIBE_TASKGROUP_ARTIFACT_DIR
fi

# Each build uses an isolated cache. Matching bytes alone cannot prove reuse:
# the strict compiler telemetry must report zero checks after publication.
node --input-type=module - "$PROJECT_ROOT" "$COMPILER_WASM" <<'NODE'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const [repo, compiler] = process.argv.slice(2);
const { parseIncrementalTelemetry } = await import(pathToFileURL(join(repo, "scripts/edit_cycle_kpi.mjs")));
const runner = join(repo, "scripts/run_wasm_vibe_host_runner.sh");
const publicRunner = join(repo, "runtime/viberun/target/release/viberun");
const taskgroup = process.env.VIBE_PARALLEL_BACKEND === "taskgroup";
const jobCache = taskgroup && process.env.VIBE_TASKGROUP_JOB_CACHE === "1";
const driver = join(repo, taskgroup ? "scripts/taskgroup_frontend_warm.mjs" : "scripts/parallel_frontend_warm.mjs");
const artifacts = process.env.VIBE_TASKGROUP_ARTIFACT_DIR;
if (taskgroup && !artifacts) throw new Error("TaskGroup oracle requires VIBE_TASKGROUP_ARTIFACT_DIR");
const extra = taskgroup ? [join(artifacts, "worker.wasm"), join(artifacts, "coordinator.component.wasm"),
  join(repo, "runtime/viberun/target/release/viberun")] : [];
const work = mkdtempSync(join(repo, "_build/parallel-lowering-oracle-"));
const project = join(work, "project");
mkdirSync(project);
for (const name of readdirSync(join(repo, "scripts/fixtures/parallel_project_sample"))) {
  if (name.endsWith(".vibe")) copyFileSync(join(repo, "scripts/fixtures/parallel_project_sample", name), join(project, name));
}
const base = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("VIBE_")));
const environment = cache => ({ ...base, VIBE_PREOPEN_DIR: project, VIBE_LIB: join(repo, "lib"),
  VIBE_BUILD_CACHE_DIR: cache, VIBE_CHECKED_MODULE_CACHE: "off", VIBE_CODEGEN_BODY_CACHE: "off",
  VIBE_EXPERIMENTAL_AST_CACHE: "0", VIBE_IMPORT_ABI: "raw", VIBE_RC: "1",
  ...(jobCache ? { VIBE_TASKGROUP_JOB_CACHE: "1" } : {}) });
const samples = [];
function invoke(command, args, env, cwd = project) {
  const result = spawnSync(command, args, { cwd, env, encoding: "utf8", timeout: 300_000 });
  assert.ifError(result.error);
  return result;
}
function prewarm(source, jobs, cache, settings = {}, images = extra) {
  const result = invoke("node", [driver, compiler, source, String(jobs), project, runner, ...images], { ...environment(cache), ...settings });
  assert.equal(result.status, 0, result.stderr);
  const summary = JSON.parse(result.stdout);
  console.log(`[jobs-warm] jobs=${jobs} ${source}: ${JSON.stringify(summary)}`);
  return summary;
}
function compile(label, source, entry, cache, expectedFailure = false) {
  const output = join(work, `${label}.wasm`);
  const telemetry = join(work, `${label}.telemetry.json`);
  const result = invoke("bash", [runner, "--invoke", "cli_main", compiler, source, output, entry], {
    ...environment(cache), VIBE_FS_COMPILE: "1", VIBE_RUNNER_EXIT_WITH_RESULT: "1",
    VIBE_INCREMENTAL_TELEMETRY_OUT: telemetry,
  });
  const diagnostic = existsSync(`${output}.diag`) ? readFileSync(`${output}.diag`, "utf8") : null;
  if (expectedFailure) {
    assert.notEqual(result.status, 0, "broken source unexpectedly compiled");
    assert(diagnostic, "failed compile produced no diagnostic");
    return diagnostic;
  }
  assert.equal(result.status, 0, diagnostic ?? result.stderr);
  assert(existsSync(output), "compile produced no Wasm");
  const counters = parseIncrementalTelemetry(readFileSync(telemetry, "utf8"), telemetry);
  samples.push({ label, counters });
  console.log(`[jobs-warm] ${label}: ${counters.checker_executions} checker executions`);
  return { bytes: readFileSync(output), output, counters };
}
function cacheFor(label) {
  const cache = join(work, `${label}-cache`);
  mkdirSync(cache);
  return cache;
}
function run(output, entry, expected) {
  const result = invoke("bash", [runner, "--invoke", entry, output], {
    ...base, VIBE_PREOPEN_DIR: project, VIBE_IMPORT_ABI: "raw",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim().split("\n").at(-1), String(expected));
}
function exercise(label, source, entry, expected, moduleCount) {
  const serialCache = cacheFor(`${label}-serial`);
  const cold = compile(`${label}-serial-cold`, source, entry, serialCache);
  assert(cold.counters.checker_executions > 0, "cold control did not actually check");
  const warm = compile(`${label}-serial-warm`, source, entry, serialCache);
  assert.equal(warm.counters.checker_executions, 0);
  assert.deepEqual(warm.bytes, cold.bytes);
  run(cold.output, entry, expected);
  for (const jobs of [1, 2, 4]) {
    const cache = cacheFor(`${label}-jobs-${jobs}`);
    for (const temperature of ["cold", "warm"]) {
      const summary = prewarm(source, jobs, cache);
      assert.equal(summary.modules, moduleCount);
      assert.equal(summary.checked, moduleCount);
      assert.equal(summary.warmed, moduleCount);
      if (jobCache) {
        assert.equal(summary.executed, temperature === "cold" ? moduleCount : 0);
        assert.equal(summary.reused, temperature === "cold" ? 0 : moduleCount);
      }
      const compiled = compile(`${label}-jobs-${jobs}-${temperature}`, source, entry, cache);
      assert.equal(compiled.counters.checker_executions, 0, "published workers were rechecked");
      assert.deepEqual(compiled.bytes, cold.bytes, "worker lowering changed emitted bytes");
      run(compiled.output, entry, expected);
    }
  }
  return cold;
}
try {
  exercise("diamond", "main.vibe", "main_value", 28, 3);
  writeFileSync(join(project, "typed_leaf.vibe"), `export fn render[T](value: T) -> String { __to_string(value) }
export fn mono(value: Bool) -> String { __to_string(value) }
export fn take(value: Double) -> Double { value + 0.5 }
`);
  writeFileSync(join(project, "typed_facade.vibe"), "export ./typed_leaf.vibe { render as show, mono, take }\n");
  writeFileSync(join(project, "typed_main.vibe"), `import ./typed_facade.vibe { show, mono, take }
export fn typed_main() -> Int {
  let b = () -> Bool { 1 < 2 }
  let d = () -> Double { 2.5 }
  let a = () -> Array[Bool] { [1 < 2, 2 < 1] }
  assert(show(b()) == "true")
  assert(show(d()) == "2.5")
  assert(show(a()) == "[true, false]")
  assert(mono(b()) == "true")
  assert(take(d()) == 3.0)
  let v = [1, 2]
  let w = [1, 3]
  let left = []
  let right = []
  let other = []
  Array::push(left, v)
  Array::push(right, v)
  Array::push(other, w)
  assert(left == right)
  assert(left != other)
  0
}
`);
  exercise("typed", "typed_main.vibe", "typed_main", 0, 3);

  if (jobCache) {
    // Compiler cache paths treat an empty override just like an absent one.
    // Exercise both through the actual driver, including publication.
    for (const override of [undefined, ""]) {
      const summary = prewarm("main.vibe", 4, override);
      assert.equal(summary.checked, 3);
      const directory = join(project, ".vibe/build/cache/taskgroup-jobs-v1");
      assert.equal(readdirSync(directory).filter(name => name.endsWith(".json")).length > 0, true);
      assert.equal(existsSync(join(project, "taskgroup-jobs-v1")), false,
        "empty cache override wrote replay records outside the default cache");
    }
    const replayCache = cacheFor("replay-controls");
    assert.equal(prewarm("main.vibe", 4, replayCache).executed, 3);
    const control = compile("replay-control", "main.vibe", "main_value", replayCache);
    assert.equal(prewarm("main.vibe", 4, replayCache).executed, 0);
    const directory = join(replayCache, "taskgroup-jobs-v1");
    const entry = join(directory, readdirSync(directory).find((name) => name.endsWith(".json")));
    const mutations = [
      (record) => { record.version = 999; },
      (record) => { record.input = "0".repeat(64); },
      (record) => { record.context = "0".repeat(64); },
      (record) => { record.files[2] += "corrupted lowering"; },
    ];
    for (const [index, mutate] of mutations.entries()) {
      const original = readFileSync(entry, "utf8");
      const record = JSON.parse(original); mutate(record);
      const changed = JSON.stringify(record);
      assert.notEqual(changed, original, "cache corruption mutation did not land");
      writeFileSync(entry, changed);
      const summary = prewarm("main.vibe", 4, replayCache);
      assert.equal(summary.executed, 1, "corrupt cache did not force a real check");
      assert.equal(summary.reused, 2);
      const repaired = compile(`replay-repaired-${index}`, "main.vibe", "main_value", replayCache);
      assert.equal(repaired.counters.checker_executions, 0);
      assert.deepEqual(repaired.bytes, control.bytes);
    }
    assert.equal(prewarm("main.vibe", 4, replayCache, { VIBE_CFG: "dev" }).executed, 3);
    assert.equal(prewarm("main.vibe", 4, replayCache, { VIBE_CFG: "dev" }).executed, 0);
    assert.equal(prewarm("main.vibe", 4, replayCache, { VIBE_CHECK_ERROR_ROW: "0" }).executed, 3);
    assert.equal(prewarm("main.vibe", 4, replayCache, { VIBE_CHECK_ERROR_ROW: "0" }).executed, 0);

    const producerCache = cacheFor("replay-producer");
    assert.equal(prewarm("main.vibe", 4, producerCache).executed, 3);
    const copiedWorker = join(work, "worker-control.wasm");
    copyFileSync(extra[0], copiedWorker);
    const images = [copiedWorker, ...extra.slice(1)];
    assert.equal(prewarm("main.vibe", 4, producerCache, {}, images).executed, 0);
    // A valid, unused custom section changes producer bytes at the SAME path.
    // Its behavior is unchanged, but its products must come from real checks.
    const originalWorker = readFileSync(copiedWorker);
    const name = Buffer.from("cache-control");
    const changedWorker = Buffer.concat([originalWorker, Buffer.from([0, name.length + 1, name.length]), name]);
    assert.notDeepEqual(changedWorker, originalWorker, "producer mutation did not land");
    writeFileSync(copiedWorker, changedWorker);
    assert.equal(prewarm("main.vibe", 4, producerCache, {}, images).executed, 3);
    assert.equal(prewarm("main.vibe", 4, producerCache, {}, images).executed, 0);
    assert.deepEqual(compile("replay-producer", "main.vibe", "main_value", producerCache).bytes, control.bytes);
  }

  // An unchanged signature with an edited dependency body must not keep the
  // old fingerprint, lowering product, or rendered behavior.
  const editCache = cacheFor("edit");
  prewarm("main.vibe", 4, editCache);
  const before = compile("before-edit", "main.vibe", "main_value", editCache);
  const leafPath = join(project, "leaf.vibe");
  const leaf = readFileSync(leafPath, "utf8");
  const editedLeaf = leaf.replace("n + 10", "n + 11");
  assert.notEqual(editedLeaf, leaf, "body-edit mutation did not land");
  writeFileSync(leafPath, editedLeaf);
  prewarm("main.vibe", 4, editCache);
  const edited = compile("edited-warmed", "main.vibe", "main_value", editCache);
  const editedControl = compile("edited-control", "main.vibe", "main_value", cacheFor("edited-control"));
  assert.equal(edited.counters.checker_executions, 0);
  assert.notDeepEqual(edited.bytes, before.bytes);
  assert.deepEqual(edited.bytes, editedControl.bytes);
  run(edited.output, "main_value", 30);

  const serialDiagnostic = compile("broken-serial", "main_broken.vibe", "main_value", cacheFor("broken-serial"), true);
  const brokenCache = cacheFor("broken-parallel");
  const broken = prewarm("main_broken.vibe", 4, brokenCache);
  assert.equal(broken.diagnosed, 1);
  assert.equal(broken.warmed, 2, "diagnosed module must not publish a cache entry");
  const parallelDiagnostic = compile("broken-parallel", "main_broken.vibe", "main_value", brokenCache, true);
  assert.equal(parallelDiagnostic, serialDiagnostic);
  if (jobCache) {
    const repeated = prewarm("main_broken.vibe", 4, brokenCache);
    assert.equal(repeated.executed, 1, "diagnosed module must be checked again");
    assert.equal(repeated.reused, 2, "only successful dependency products may replay");
    assert.equal(repeated.diagnosed, 1);
    assert.equal(compile("broken-repeated", "main_broken.vibe", "main_value", brokenCache, true), serialDiagnostic);
  }

  // Exercise the public relative-path --jobs adapter; canonical cache keys
  // must agree with ordinary serial builds in a separate project directory.
  const builds = [];
  for (const jobs of [1, 4]) {
    const cwd = join(work, `relative-${jobs}`);
    mkdirSync(cwd);
    for (const name of ["leaf.vibe", "mid.vibe", "main.vibe"]) copyFileSync(join(project, name), join(cwd, name));
    const cache = cacheFor(`relative-${jobs}`);
    const result = invoke("bash", [join(repo, "runtime/vibe"), "build", "main.vibe", "-o", "out.wasm",
      "--entry", "main_value", "--jobs", String(jobs)], {
      ...environment(cache), VIBE_PREOPEN_DIR: cwd, VIBE_RUNNER: publicRunner, VIBE_CLI_WASM: compiler,
      VIBE_TASKGROUP_ARTIFACT_DIR: artifacts,
    }, cwd);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /pre-warm failed/i);
    const keys = readdirSync(cache).filter(name => name.includes("selfhost_type_env_")).sort();
    assert.equal(keys.length, 3, "relative build did not publish all module cache entries");
    builds.push({ keys, bytes: readFileSync(join(cwd, "out.wasm")) });
  }
  assert.deepEqual(builds[0], builds[1], "relative --jobs changed cache keys or emitted bytes");
  writeFileSync(join(work, "results.json"), JSON.stringify({ status: "passed", compiler, samples }, null, 2) + "\n");
  console.log(`[jobs-warm] lowering reuse, execution, invalidation, diagnostics, relative paths passed: ${work}`);
} finally {
  if (!process.env.VIBE_PARALLEL_ORACLE_KEEP) rmSync(work, { recursive: true, force: true });
}
NODE
