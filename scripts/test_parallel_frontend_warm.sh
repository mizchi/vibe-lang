#!/usr/bin/env bash
# #906 Phase 2 (real-build wiring): end-to-end proof that
# scripts/parallel_frontend_warm.mjs's cache pre-warm never changes what a
# real compile produces, and that it actually warms the persistent cache
# rather than silently no-op'ing.
#
# This intentionally does NOT go through runtime/vibe (which needs the
# viberun Rust runner built) -- it drives the exact same VIBE_FS_COMPILE=1
# invocation compile_to() uses, directly against the Node runner, mirroring
# how every other scripts/test_*.sh in this repo exercises the compiler.
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
const taskgroup = process.env.VIBE_PARALLEL_BACKEND === "taskgroup";
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
  VIBE_EXPERIMENTAL_AST_CACHE: "0", VIBE_IMPORT_ABI: "raw", VIBE_RC: "1" });
const samples = [];
function invoke(command, args, env, cwd = project) {
  const result = spawnSync(command, args, { cwd, env, encoding: "utf8", timeout: 300_000 });
  assert.ifError(result.error);
  return result;
}
function prewarm(source, jobs, cache) {
  const result = invoke("node", [driver, compiler, source, String(jobs), project, runner, ...extra], environment(cache));
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
      ...environment(cache), VIBE_PREOPEN_DIR: cwd, VIBE_RUNNER: runner, VIBE_CLI_WASM: compiler,
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
