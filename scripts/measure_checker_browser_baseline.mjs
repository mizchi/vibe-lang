#!/usr/bin/env node
// Opt-in observation baseline for #1440. It deliberately measures build roots
// and their compiler-reported source closures; it does not define a checker ABI.

import { spawnSync } from "node:child_process";
import { brotliCompressSync, constants as zlibConstants, gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { arch, cpus, platform, release, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runner = join(root, "scripts/run_wasm_vibe_host_runner.sh");
const schema = 1;
const caseDefinitions = [
  { id: "parser_only", root: "bench/checker_browser_baseline/parser_only.vibe", entry: "main" },
  { id: "current_checker", root: "bench/checker_browser_baseline/current_checker.vibe", entry: "main" },
  // This is the compiler's actual self-host CLI root. The failed facade-only
  // experiment is intentionally not a benchmark root: it is not buildable.
  { id: "full_compiler", root: "lib/@vibe/compiler/cli_adapter.vibe", entry: "cli_main" },
];
const unavailableDefinitions = [
  ["checker_engine_only", "No supported isolated checker-engine root or ABI exists; this baseline does not extract one."],
  ["checker_engine_plus_artifacts", "No supported isolated checker-engine-plus-artifacts entry exists; this baseline does not infer one from imports."],
  ["full_compiler_check", "The full compiler CLI exposes no supported isolated direct check invocation ABI; host imports and CLI argument ABI are not fabricated."],
];

function fail(message) {
  throw new Error(`checker-browser-baseline: ${message}`);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
}

function exactKeys(value, keys, label) {
  object(value, label);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) fail(`${label} has unexpected or missing fields`);
}

function nonempty(value, label) {
  if (typeof value !== "string" || value.length === 0) fail(`invalid ${label}`);
}

function nonnegative(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`invalid ${label}`);
}

function positive(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) fail(`invalid ${label}`);
}

function digest(value, label) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) fail(`invalid ${label}`);
}

function compareImports(a, b) {
  for (const key of ["module", "name", "kind"]) {
    if (a[key] < b[key]) return -1;
    if (a[key] > b[key]) return 1;
  }
  return 0;
}

function compareModulePaths(a, b) {
  const left = [...a];
  const right = [...b];
  const limit = Math.min(left.length, right.length);
  for (let index = 0; index < limit; index += 1) {
    const leftCode = left[index].codePointAt(0);
    const rightCode = right[index].codePointAt(0);
    if (leftCode < rightCode) return -1;
    if (leftCode > rightCode) return 1;
  }
  return left.length - right.length;
}

function validateCanonicalPlan(modules, label) {
  const ranks = new Map(modules.map((module) => [module.path, module.rank]));
  for (const [index, module] of modules.entries()) {
    let expectedRank = 0;
    for (const dependency of module.dependencies) {
      if (!ranks.has(dependency)) fail(`${label} dependency is absent from closure: ${dependency}`);
      expectedRank = Math.max(expectedRank, ranks.get(dependency) + 1);
    }
    if (module.rank !== expectedRank) fail(`${label} has noncanonical rank for ${module.path}`);
    if (index > 0) {
      const previous = modules[index - 1];
      if (previous.rank > module.rank || (previous.rank === module.rank && compareModulePaths(previous.path, module.path) >= 0)) fail(`${label} is not sorted by canonical rank/path order`);
    }
  }
}

/** Parse exactly the VIBE_MODULE_PLAN=1 version-1 sidecar format. */
export function parseModulePlan(text) {
  if (typeof text !== "string") fail("module plan must be text");
  const rows = text.split("\n").filter((row) => row.length > 0);
  if (rows.shift() !== "version\t1") fail("unsupported module plan version");
  const modules = [];
  const paths = new Set();
  let current;
  for (const row of rows) {
    const parts = row.split("\t");
    if (parts[0] === "module" && parts.length === 4) {
      const [_, indexText, rankText, path] = parts;
      const index = Number(indexText);
      const rank = Number(rankText);
      if (index !== modules.length || !Number.isSafeInteger(rank) || rank < 0 || !path || paths.has(path)) fail(`noncanonical module plan row: ${row}`);
      current = { index, rank, path, dependencies: [] };
      modules.push(current);
      paths.add(path);
    } else if (parts[0] === "dep" && parts.length === 3) {
      const index = Number(parts[1]);
      if (!current || index !== current.index || !parts[2]) fail(`noncanonical dependency plan row: ${row}`);
      current.dependencies.push(parts[2]);
    } else {
      fail(`invalid module plan row: ${row}`);
    }
  }
  if (modules.length === 0) fail("module plan has no modules");
  validateCanonicalPlan(modules, "module plan");
  return modules;
}

function sourceManifestAnnotations() {
  const path = join(root, "lib/@vibe/compiler/compiler_sources_manifest.tsv");
  const annotations = new Map();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line || line.startsWith("#")) continue;
    const fields = line.split("\t");
    if (fields.length < 2) continue;
    const listedPath = fields[1];
    const manifestPath = listedPath.startsWith("../../../")
      ? listedPath.slice("../../../".length)
      : `lib/@vibe/compiler/${listedPath}`;
    annotations.set(manifestPath, fields[0] || "unlabeled");
  }
  return annotations;
}

function category(path) {
  if (path.startsWith("bench/checker_browser_baseline/")) return "benchmark_root";
  if (path.startsWith("lib/@vibe/compiler/checker/")) {
    if (path.endsWith("_artifact.vibe")) return "checker_artifact";
    if (path.endsWith("_observation.vibe")) return "checker_observation";
    return "checker_core_and_model";
  }
  if (path.startsWith("lib/@vibe/compiler/codegen/") || path.startsWith("lib/@vibe/compiler/perceus/")) return "codegen";
  if (path.startsWith("lib/@vibe/parser/")) return "parser";
  if (path.startsWith("lib/@vibe/compiler/")) return "compiler_other";
  if (path.startsWith("lib/@vibe/")) return "stdlib_other";
  return "other";
}

function digestClosure(plan, planPath) {
  const annotations = sourceManifestAnnotations();
  const categories = {};
  let totalBytes = 0;
  const modules = plan.map((module) => {
    const sourcePath = `${planPath}.${module.index}.src`;
    if (!existsSync(sourcePath)) fail(`module plan source sidecar missing: ${basename(sourcePath)}`);
    const source = readFileSync(sourcePath);
    const bytes = source.length;
    const itemCategory = category(module.path);
    totalBytes += bytes;
    if (!categories[itemCategory]) categories[itemCategory] = { modules: 0, bytes: 0 };
    categories[itemCategory].modules += 1;
    categories[itemCategory].bytes += bytes;
    return {
      index: module.index,
      rank: module.rank,
      path: module.path,
      dependencies: module.dependencies,
      bytes,
      sha256: sha256(source),
      category: itemCategory,
      manifest_annotation: annotations.get(module.path) ?? "not-listed",
    };
  });
  const identity = modules.map((item) => `${item.index}\t${item.rank}\t${item.path}\t${item.bytes}\t${item.sha256}\t${item.dependencies.join("\u0000")}`).join("\n");
  return { module_count: modules.length, total_bytes: totalBytes, sha256: sha256(identity), modules, category_breakdown: categories };
}

function environment(workdir) {
  return {
    node: process.version,
    v8: process.versions.v8,
    platform: platform(),
    release: release(),
    arch: arch(),
    cpu_model: cpus()[0]?.model ?? "unknown",
    cpu_count: cpus().length,
    cwd: root,
    isolated_workdir_parent: relative(root, dirname(workdir)),
  };
}

function relativeToRoot(path) {
  return isAbsolute(path) ? relative(root, path) : path;
}

export function isolatedCompilerEnvironment(overrides, inherited = process.env) {
  const environment = {};
  for (const [name, value] of Object.entries(inherited)) {
    if (!name.startsWith("VIBE_")) environment[name] = value;
  }
  return { ...environment, ...overrides };
}

function compilerCall(stage2, args, env) {
  const result = spawnSync("bash", [runner, "--invoke", "cli_main", stage2, ...args], {
    cwd: root,
    encoding: "utf8",
    env: isolatedCompilerEnvironment(env),
  });
  if (result.error) fail(`could not start supplied compiler: ${result.error.message}`);
  return result;
}

function compilerEnv(cache) {
  return {
    VIBE_PREOPEN_DIR: root,
    VIBE_BUILD_CACHE_DIR: cache,
    VIBE_IMPORT_ABI: "raw",
    VIBE_RC: "0",
    // Do not consult a user-level or production artifact cache.
    VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
  };
}

function planCase(stage2, definition, workdir) {
  const planPath = join(workdir, definition.id, "module-plan.txt");
  const cache = join(workdir, definition.id, "plan-cache");
  mkdirSync(cache, { recursive: true });
  const result = compilerCall(stage2, [definition.root, relativeToRoot(planPath), "__no_entry__"], {
    ...compilerEnv(cache), VIBE_MODULE_PLAN: "1",
  });
  if (result.status !== 0 || !existsSync(planPath)) {
    const detail = `${result.stderr ?? ""}${result.stdout ?? ""}`.trim();
    throw new Error(`VIBE_MODULE_PLAN failed (${result.status ?? "signal"}): ${detail || "no sidecar"}`);
  }
  return { planPath, closure: digestClosure(parseModulePlan(readFileSync(planPath, "utf8")), planPath) };
}

function buildCase(stage2, definition, workdir, count) {
  const artifacts = [];
  const build_ms = [];
  for (let sample = 0; sample < count; sample += 1) {
    const runDir = join(workdir, definition.id, `build-${sample}`);
    const cache = join(runDir, "cache");
    const output = join(runDir, "core.wasm");
    mkdirSync(cache, { recursive: true });
    const started = performance.now();
    const result = compilerCall(stage2, [definition.root, relativeToRoot(output), definition.entry], {
      ...compilerEnv(cache), VIBE_FS_COMPILE: "1",
    });
    build_ms.push(performance.now() - started);
    if (result.status !== 0 || !existsSync(output) || statSync(output).size === 0) {
      const detail = `${result.stderr ?? ""}${result.stdout ?? ""}`.trim();
      throw new Error(`isolated build ${sample} failed (${result.status ?? "signal"}): ${detail || "no wasm output"}`);
    }
    artifacts.push(readFileSync(output));
  }
  return { artifacts, build_ms };
}

async function wasmMeasurements(bytes, entry, count) {
  const timings = { wasm_compile_ms: [], wasm_instantiate_ms: [], direct_entry_ms: [], unsupported: {} };
  let imports;
  try {
    imports = WebAssembly.Module.imports(new WebAssembly.Module(bytes))
      .map(({ module, name, kind }) => ({ module, name, kind }))
      .sort(compareImports);
  } catch (error) {
    timings.unsupported.wasm_compile = `Node WebAssembly.Module rejected the core Wasm: ${error.message}`;
    timings.unsupported.wasm_instantiate = "No Node-compiled core Wasm module is available.";
    timings.unsupported.direct_entry = "No Node-compiled core Wasm module is available.";
    return { imports: [], timings };
  }
  let compiled;
  try {
    for (let sample = 0; sample < count; sample += 1) {
      const started = performance.now();
      compiled = await WebAssembly.compile(bytes);
      timings.wasm_compile_ms.push(performance.now() - started);
    }
  } catch (error) {
    timings.unsupported.wasm_compile = `Node WebAssembly.compile rejected the core Wasm: ${error.message}`;
    return { imports, timings };
  }
  if (imports.length !== 0) {
    timings.unsupported.wasm_instantiate = "Core Wasm imports host bindings; this baseline does not fabricate them.";
    timings.unsupported.direct_entry = "Direct entry timing requires honest instantiation without fabricated host imports.";
    return { imports, timings };
  }
  let instance;
  try {
    for (let sample = 0; sample < count; sample += 1) {
      const started = performance.now();
      instance = await WebAssembly.instantiate(compiled, {});
      timings.wasm_instantiate_ms.push(performance.now() - started);
    }
  } catch (error) {
    timings.unsupported.wasm_instantiate = `Node WebAssembly.instantiate failed: ${error.message}`;
    timings.unsupported.direct_entry = "No successfully instantiated direct entry.";
    return { imports, timings };
  }
  const callable = instance.exports[entry];
  if (typeof callable !== "function") {
    timings.unsupported.direct_entry = `No exported callable named ${entry}.`;
    return { imports, timings };
  }
  try {
    for (let sample = 0; sample < count; sample += 1) {
      const started = performance.now();
      callable();
      timings.direct_entry_ms.push(performance.now() - started);
    }
  } catch (error) {
    timings.unsupported.direct_entry = `Direct ${entry} invocation failed: ${error.message}`;
  }
  return { imports, timings };
}

async function measureAvailableCase(stage2, definition, workdir, samples) {
  const planned = planCase(stage2, definition, workdir);
  const built = buildCase(stage2, definition, workdir, samples);
  const first = built.artifacts[0];
  const repeatedArtifactsEqual = built.artifacts.every((artifact) => artifact.equals(first));
  if (!repeatedArtifactsEqual) fail(`${definition.id} produced non-deterministic core Wasm bytes`);
  const wasm = await wasmMeasurements(first, definition.entry, samples);
  const hashes = built.artifacts.map(sha256);
  return {
    id: definition.id,
    status: "available",
    root: { path: definition.root, entry: definition.entry },
    module_plan: { authority: "VIBE_MODULE_PLAN=1 version 1 sidecar; ingested .src files", dependency_order: "canonical compiler plan order (index ascending)", ...planned.closure },
    artifacts: {
      raw_bytes: first.length,
      gzip_bytes: gzipSync(first, { level: 9 }).length,
      brotli_bytes: brotliCompressSync(first, { params: { [zlibConstants.BROTLI_PARAM_MODE]: zlibConstants.BROTLI_MODE_GENERIC, [zlibConstants.BROTLI_PARAM_QUALITY]: 11 } }).length,
      sha256: hashes[0],
      imports: wasm.imports,
      repeated_sha256: hashes,
      repeated_artifacts_equal: repeatedArtifactsEqual,
    },
    timings: { build_ms: built.build_ms, ...wasm.timings },
  };
}

/** Strictly validate reports written by this script before they reach disk. */
export function parseCheckerBrowserBaselineReport(text) {
  let report;
  try { report = JSON.parse(text); } catch (error) { fail(`invalid report JSON: ${error.message}`); }
  exactKeys(report, ["schema", "methodology", "environment", "compiler", "cases"], "report");
  if (report.schema !== schema) fail(`unsupported report schema ${JSON.stringify(report.schema)}`);
  exactKeys(report.methodology, ["opt_in", "cache_policy", "source_authority", "unavailable_policy", "timing_policy", "samples"], "methodology");
  if (report.methodology.opt_in !== true || report.methodology.source_authority !== "VIBE_MODULE_PLAN=1") fail("dishonest methodology");
  for (const key of ["cache_policy", "unavailable_policy", "timing_policy"]) nonempty(report.methodology[key], `methodology ${key}`);
  if (!Number.isSafeInteger(report.methodology.samples) || report.methodology.samples < 2) fail("invalid sample count");
  exactKeys(report.environment, ["node", "v8", "platform", "release", "arch", "cpu_model", "cpu_count", "cwd", "isolated_workdir_parent"], "environment");
  for (const key of ["node", "v8", "platform", "release", "arch", "cpu_model", "cwd", "isolated_workdir_parent"]) nonempty(report.environment[key], `environment ${key}`);
  nonnegative(report.environment.cpu_count, "environment cpu_count");
  exactKeys(report.compiler, ["path", "sha256", "matching_contract"], "compiler");
  nonempty(report.compiler.path, "compiler path"); digest(report.compiler.sha256, "compiler sha256"); nonempty(report.compiler.matching_contract, "matching contract");
  if (!Array.isArray(report.cases) || report.cases.length !== 6) fail("report must contain the six fixed cases");
  const expectedIds = [...caseDefinitions.map((item) => item.id), ...unavailableDefinitions.map(([id]) => id)];
  if (JSON.stringify(report.cases.map((item) => item.id)) !== JSON.stringify(expectedIds)) fail("report case order or IDs changed");
  for (const [caseIndex, item] of report.cases.entries()) {
    object(item, `case ${item.id}`);
    if (caseIndex < caseDefinitions.length && item.status !== "available") fail(`required measured case is unavailable: ${item.id}`);
    if (caseIndex >= caseDefinitions.length && item.status !== "unavailable") fail(`unsupported case was presented as available: ${item.id}`);
    if (item.status === "unavailable") {
      exactKeys(item, ["id", "status", "unavailable_reason"], `unavailable case ${item.id}`);
      nonempty(item.unavailable_reason, `unavailable reason ${item.id}`);
    } else if (item.status === "available") {
      exactKeys(item, ["id", "status", "root", "module_plan", "artifacts", "timings"], `available case ${item.id}`);
      exactKeys(item.root, ["path", "entry"], `root ${item.id}`);
      const expectedRoot = caseDefinitions[caseIndex];
      if (item.root.path !== expectedRoot.root || item.root.entry !== expectedRoot.entry) fail(`unexpected fixed root for ${item.id}`);
      exactKeys(item.module_plan, ["authority", "dependency_order", "module_count", "total_bytes", "sha256", "modules", "category_breakdown"], `module plan ${item.id}`);
      if (item.module_plan.authority !== "VIBE_MODULE_PLAN=1 version 1 sidecar; ingested .src files") fail(`dishonest module-plan authority for ${item.id}`);
      nonempty(item.module_plan.dependency_order, `${item.id} dependency order`); digest(item.module_plan.sha256, `${item.id} closure sha256`);
      positive(item.module_plan.module_count, `${item.id} module count`); positive(item.module_plan.total_bytes, `${item.id} closure bytes`);
      if (!Array.isArray(item.module_plan.modules) || item.module_plan.modules.length !== item.module_plan.module_count) fail(`invalid module list for ${item.id}`);
      const modulePaths = new Map();
      const computedCategories = {};
      let computedBytes = 0;
      for (const [moduleIndex, module] of item.module_plan.modules.entries()) {
        exactKeys(module, ["index", "rank", "path", "dependencies", "bytes", "sha256", "category", "manifest_annotation"], `module ${item.id}`);
        if (module.index !== moduleIndex) fail(`noncanonical module index for ${item.id}`);
        nonnegative(module.rank, `${item.id} module rank`); positive(module.bytes, `${item.id} module bytes`);
        for (const key of ["path", "category", "manifest_annotation"]) nonempty(module[key], `${item.id} module ${key}`);
        digest(module.sha256, `${item.id} module sha256`);
        if (modulePaths.has(module.path)) fail(`duplicate module path for ${item.id}`);
        modulePaths.set(module.path, module.rank);
        if (!Array.isArray(module.dependencies) || module.dependencies.some((dependency) => typeof dependency !== "string" || dependency.length === 0)) fail(`invalid module dependencies for ${item.id}`);
        computedBytes += module.bytes;
        if (!computedCategories[module.category]) computedCategories[module.category] = { modules: 0, bytes: 0 };
        computedCategories[module.category].modules += 1;
        computedCategories[module.category].bytes += module.bytes;
      }
      validateCanonicalPlan(item.module_plan.modules, `report module plan ${item.id}`);
      if (computedBytes !== item.module_plan.total_bytes) fail(`source byte total mismatch for ${item.id}`);
      const closureIdentity = item.module_plan.modules.map((module) => `${module.index}\t${module.rank}\t${module.path}\t${module.bytes}\t${module.sha256}\t${module.dependencies.join("\u0000")}`).join("\n");
      if (sha256(closureIdentity) !== item.module_plan.sha256) fail(`closure digest mismatch for ${item.id}`);
      object(item.module_plan.category_breakdown, `category breakdown ${item.id}`);
      if (JSON.stringify(item.module_plan.category_breakdown) !== JSON.stringify(computedCategories)) fail(`category breakdown mismatch for ${item.id}`);
      exactKeys(item.artifacts, ["raw_bytes", "gzip_bytes", "brotli_bytes", "sha256", "imports", "repeated_sha256", "repeated_artifacts_equal"], `artifacts ${item.id}`);
      for (const key of ["raw_bytes", "gzip_bytes", "brotli_bytes"]) positive(item.artifacts[key], `${item.id} ${key}`);
      digest(item.artifacts.sha256, `${item.id} artifact sha256`);
      if (item.artifacts.repeated_artifacts_equal !== true || !Array.isArray(item.artifacts.imports) || !Array.isArray(item.artifacts.repeated_sha256) || item.artifacts.repeated_sha256.length !== report.methodology.samples) fail(`invalid artifact evidence for ${item.id}`);
      for (const hash of item.artifacts.repeated_sha256) {
        digest(hash, `${item.id} repeated artifact sha256`);
        if (hash !== item.artifacts.sha256) fail(`repeated artifact digest mismatch for ${item.id}`);
      }
      for (const [importIndex, wasmImport] of item.artifacts.imports.entries()) {
        exactKeys(wasmImport, ["module", "name", "kind"], `Wasm import ${item.id}`);
        for (const key of ["module", "name", "kind"]) nonempty(wasmImport[key], `${item.id} Wasm import ${key}`);
        if (importIndex > 0 && compareImports(item.artifacts.imports[importIndex - 1], wasmImport) > 0) fail(`noncanonical Wasm import order for ${item.id}`);
      }
      exactKeys(item.timings, ["build_ms", "wasm_compile_ms", "wasm_instantiate_ms", "direct_entry_ms", "unsupported"], `timings ${item.id}`);
      for (const key of ["build_ms", "wasm_compile_ms", "wasm_instantiate_ms", "direct_entry_ms"]) {
        if (!Array.isArray(item.timings[key]) || item.timings[key].some((value) => typeof value !== "number" || !Number.isFinite(value) || value < 0)) fail(`invalid ${key} for ${item.id}`);
      }
      object(item.timings.unsupported, `unsupported timings ${item.id}`);
      for (const [key, reason] of Object.entries(item.timings.unsupported)) {
        if (!["wasm_compile", "wasm_instantiate", "direct_entry"].includes(key)) fail(`unknown unsupported timing ${key} for ${item.id}`);
        nonempty(reason, `${item.id} unsupported ${key}`);
      }
      if (item.timings.build_ms.length !== report.methodology.samples) fail(`build sample count mismatch for ${item.id}`);
      for (const [key, unsupportedKey] of [["wasm_compile_ms", "wasm_compile"], ["wasm_instantiate_ms", "wasm_instantiate"], ["direct_entry_ms", "direct_entry"]]) {
        const expectedLength = Object.hasOwn(item.timings.unsupported, unsupportedKey) ? 0 : report.methodology.samples;
        if (item.timings[key].length !== expectedLength) fail(`${key} sample count mismatch for ${item.id}`);
      }
    } else fail(`invalid case status for ${item.id}`);
  }
  return report;
}

function parseArgs(argv) {
  let stage2;
  let out = join(root, "_build/checker_browser_baseline/report.json");
  let samples = 2;
  let keepWork = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--out") out = resolve(root, argv[++index] ?? "");
    else if (arg === "--samples") samples = Number(argv[++index]);
    else if (arg === "--keep-work") keepWork = true;
    else if (arg === "--help") return { help: true };
    else if (!stage2) stage2 = resolve(root, arg);
    else fail(`unknown argument: ${arg}`);
  }
  if (!stage2) fail("usage: measure_checker_browser_baseline.mjs <matching-stage2.wasm> [--out path] [--samples N] [--keep-work]");
  if (!Number.isSafeInteger(samples) || samples < 2) fail("--samples must be an integer of at least 2 for repeated artifact equality");
  return { stage2, out, samples, keepWork };
}

export async function runCheckerBrowserBaseline(options) {
  if (!existsSync(options.stage2)) fail(`supplied stage2 does not exist: ${options.stage2}`);
  if (!existsSync(runner)) fail("missing wasm host runner");
  mkdirSync(dirname(options.out), { recursive: true });
  const workdir = mkdtempSync(join(dirname(options.out), ".work-"));
  try {
    const compilerBytes = readFileSync(options.stage2);
    const report = {
      schema,
      methodology: {
        opt_in: true,
        cache_policy: "Every plan and build uses a new VIBE_BUILD_CACHE_DIR under the isolated workdir; persistent artifact cache is disabled.",
        source_authority: "VIBE_MODULE_PLAN=1",
        unavailable_policy: "Unsupported roots, host imports, and direct invocation ABIs are explicit unavailable/reason fields, never zero metrics.",
        timing_policy: "Raw millisecond samples are environment-sensitive; artifact hashes, source closure digests, and repeated artifact equality are deterministic evidence for a matching compiler/source pair.",
        samples: options.samples,
      },
      environment: environment(workdir),
      compiler: {
        path: relativeToRoot(options.stage2),
        sha256: sha256(compilerBytes),
        matching_contract: "Caller supplies the stage2 built from the source under measurement; this report uses that one compiler for plan and every build.",
      },
      cases: [],
    };
    for (const definition of caseDefinitions) report.cases.push(await measureAvailableCase(options.stage2, definition, workdir, options.samples));
    for (const [id, unavailable_reason] of unavailableDefinitions) report.cases.push({ id, status: "unavailable", unavailable_reason });
    const serialized = `${JSON.stringify(report, null, 2)}\n`;
    parseCheckerBrowserBaselineReport(serialized);
    writeFileSync(options.out, serialized);
    return report;
  } finally {
    if (options.keepWork) console.error(`checker-browser-baseline: kept isolated workdir ${workdir}`);
    else rmSync(workdir, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // The compiler's linear Wasm uses exception references. Re-exec when this
  // Node supports the required flag so `WebAssembly.Module`/compile metrics
  // inspect the real core bytes rather than silently treating them as invalid.
  // Keep the graceful unsupported path in wasmMeasurements for older Nodes.
  if (!process.execArgv.includes("--experimental-wasm-exnref") && process.env.VIBE_CHECKER_BROWSER_BASELINE_REEXEC !== "1") {
    const probe = spawnSync(process.execPath, ["--experimental-wasm-exnref", "-e", ""], { stdio: "ignore" });
    if (probe.status === 0) {
      const child = spawnSync(process.execPath, ["--experimental-wasm-exnref", fileURLToPath(import.meta.url), ...process.argv.slice(2)], {
        stdio: "inherit",
        env: { ...process.env, VIBE_CHECKER_BROWSER_BASELINE_REEXEC: "1" },
      });
      if (child.error) fail(`could not re-exec Node with wasm exception support: ${child.error.message}`);
      process.exit(child.status ?? 1);
    }
  }
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log("usage: node scripts/measure_checker_browser_baseline.mjs <matching-stage2.wasm> [--out path] [--samples N] [--keep-work]");
  } else {
    runCheckerBrowserBaseline(options).then((report) => {
      console.log(JSON.stringify({ schema: report.schema, report: relativeToRoot(options.out), available_cases: report.cases.filter((item) => item.status === "available").map((item) => item.id) }));
    }).catch((error) => { console.error(error.message); process.exitCode = 1; });
  }
}
