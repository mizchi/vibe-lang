#!/usr/bin/env node
// Bounded, observation-only oracle for the file_compile persistent pre-strip
// WASI bump lane. This intentionally does not inspect or change cache files.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expectedKeys = [
  "schema", "run_nonce", "scope_disclaimer", "compile_lane", "persistent_artifact_kind",
  "entry", "source_groups_fingerprint", "source_groups_fingerprint_kind",
  "production_artifact_input_fingerprint", "production_artifact_input_fingerprint_kind",
  "compiler_cache_version_tag", "compiler_cache_version_tag_kind", "effective_config",
  "dependency_plan", "resolution", "shadow_artifact_input_fingerprint",
  "shadow_artifact_input_fingerprint_kind", "persistent_lookup",
].sort();
const configKeys = ["checked_error_row_mode", "diagnostics_mode", "dep_order_seed", "target", "memory", "dce_mode", "strip_stage", "instrumentation"].sort();
const planKeys = ["fingerprint", "fingerprint_kind", "module_count", "edge_occurrence_count"].sort();
const resolutionKeys = ["env_seed", "env_seed_kind", "context_fingerprint", "context_fingerprint_kind"].sort();
const productionKind = "build_file_compile_wasi_artifact_fingerprint_from_group_fingerprint_for_entry_path(source_groups_fingerprint, entry_path, entry_name, mode)";
const planKind = "compact_string_fingerprint(vibe-artifact-input-dependency-plan:v1 length-prefixed planned order/ranks/dependency occurrences)";
const shadowKind = "compact_string_fingerprint(vibe-artifact-input-observation:v2 fixed-order length-prefixed components)";

function fail(message) {
  throw new Error(`artifact-input-trace-oracle: ${message}`);
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(keys)) fail(`${label} has unexpected or missing fields`);
}

function nonemptyString(value, label) {
  if (typeof value !== "string" || value.length === 0) fail(`missing ${label}`);
}

function nonnegativeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`invalid ${label}`);
}

/// Strict parser for successful schema-2 artifact-input observations only.
export function parseArtifactInputTrace(text, expectedNonce = undefined) {
  let trace;
  try {
    trace = JSON.parse(text);
  } catch (error) {
    fail(`invalid JSON (${error.message})`);
  }
  exactKeys(trace, expectedKeys, "trace");
  if (trace.schema !== 2) fail(`unsupported schema ${JSON.stringify(trace.schema)}`);
  for (const key of ["run_nonce", "scope_disclaimer", "compile_lane", "persistent_artifact_kind", "source_groups_fingerprint", "source_groups_fingerprint_kind", "production_artifact_input_fingerprint", "production_artifact_input_fingerprint_kind", "compiler_cache_version_tag", "compiler_cache_version_tag_kind", "shadow_artifact_input_fingerprint", "shadow_artifact_input_fingerprint_kind", "persistent_lookup"]) nonemptyString(trace[key], key);
  if (expectedNonce !== undefined && trace.run_nonce !== expectedNonce) fail("run_nonce mismatch (stale sidecar)");
  if (trace.compile_lane !== "file_compile.persistent_pre_strip_wasi_cached_bump") fail("wrong compile lane");
  if (trace.persistent_artifact_kind !== "file-compile-wasi") fail("wrong persistent artifact kind");
  if (!trace.scope_disclaimer.includes("observation-only") || !trace.scope_disclaimer.includes("not a production cache key")) fail("missing scope disclaimer");
  exactKeys(trace.entry, ["mode", "name", "path"], "entry");
  for (const key of ["path", "name", "mode"]) nonemptyString(trace.entry[key], `entry ${key}`);
  if (trace.entry.mode !== "no-dce") fail("wrong entry mode");
  if (trace.source_groups_fingerprint_kind !== "build_source_groups_fingerprint(source_groups)") fail("dishonest source groups fingerprint kind");
  if (trace.production_artifact_input_fingerprint_kind !== productionKind) fail("dishonest production artifact fingerprint kind");
  if (trace.compiler_cache_version_tag_kind !== "persistent_cache_version_tag()") fail("dishonest compiler cache version kind");
  if (trace.shadow_artifact_input_fingerprint_kind !== shadowKind) fail("dishonest shadow artifact fingerprint kind");
  if (trace.persistent_lookup !== "hit" && trace.persistent_lookup !== "miss") fail("invalid persistent lookup");

  exactKeys(trace.effective_config, configKeys, "effective_config");
  const config = trace.effective_config;
  if (config.checked_error_row_mode !== "checked" && config.checked_error_row_mode !== "unchecked") fail("invalid checked Error-row mode");
  if (config.diagnostics_mode !== "all" && config.diagnostics_mode !== "fail-fast") fail("invalid diagnostics mode");
  if (typeof config.dep_order_seed !== "string" || !/^(0|-?[1-9]\d*)$/.test(config.dep_order_seed)) fail("invalid normalized dep-order seed");
  if (config.target !== "wasi" || config.memory !== "bump" || config.dce_mode !== "no-dce" || config.strip_stage !== "pre-strip" || config.instrumentation !== "uninstrumented") fail("dishonest fixed lane config");

  exactKeys(trace.dependency_plan, planKeys, "dependency_plan");
  nonemptyString(trace.dependency_plan.fingerprint, "dependency plan fingerprint");
  if (trace.dependency_plan.fingerprint_kind !== planKind) fail("dishonest dependency plan fingerprint kind");
  nonnegativeInteger(trace.dependency_plan.module_count, "dependency plan module count");
  nonnegativeInteger(trace.dependency_plan.edge_occurrence_count, "dependency plan edge occurrence count");
  if (trace.dependency_plan.module_count === 0) fail("empty dependency plan");

  exactKeys(trace.resolution, resolutionKeys, "resolution");
  nonemptyString(trace.resolution.env_seed, "resolution env seed");
  nonemptyString(trace.resolution.context_fingerprint, "resolution context fingerprint");
  if (trace.resolution.env_seed_kind !== "resolution_env_seed()") fail("dishonest resolution env seed kind");
  if (trace.resolution.context_fingerprint_kind !== "persistent_resolution_context_fingerprint_fs(entry_path, grouped_source_paths(source_groups))") fail("dishonest resolution context fingerprint kind");
  return trace;
}

function stableIdentity(trace) {
  return {
    compile_lane: trace.compile_lane,
    persistent_artifact_kind: trace.persistent_artifact_kind,
    entry: trace.entry,
    source_groups_fingerprint: trace.source_groups_fingerprint,
    source_groups_fingerprint_kind: trace.source_groups_fingerprint_kind,
    production_artifact_input_fingerprint: trace.production_artifact_input_fingerprint,
    production_artifact_input_fingerprint_kind: trace.production_artifact_input_fingerprint_kind,
    compiler_cache_version_tag: trace.compiler_cache_version_tag,
    compiler_cache_version_tag_kind: trace.compiler_cache_version_tag_kind,
    effective_config: trace.effective_config,
    dependency_plan: trace.dependency_plan,
    resolution: trace.resolution,
    shadow_artifact_input_fingerprint: trace.shadow_artifact_input_fingerprint,
    shadow_artifact_input_fingerprint_kind: trace.shadow_artifact_input_fingerprint_kind,
  };
}

function run(stage2) {
  const invoke = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  if (![stage2, invoke].every(existsSync)) fail("missing stage2 compiler or host runner");
  const work = mkdtempSync(join(root, "_build/artifact-input-trace-"));
  const rel = (path) => relative(root, path);
  const project = join(work, "project");
  const cache = join(work, "cache");
  const resolutionRoot = join(work, "resolution-root");
  try {
    mkdirSync(project, { recursive: true });
    writeFileSync(join(project, "dep.vibe"), "export fn answer() -> Int { 41 }\nexport fn second() -> Int { 1 }\n");
    writeFileSync(join(project, "dep2.vibe"), "export fn other() -> Int { 1 }\n");
    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nexport fn main() -> Int { answer() + 1 }\n");
    const compile = (name, nonce, expectSuccess = true, extraEnv = {}) => {
      const out = join(project, `${name}.wasm`);
      const tracePath = join(project, `${name}.trace.json`);
      rmSync(out, { force: true });
      writeFileSync(tracePath, "stale");
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, rel(join(project, "main.vibe")), rel(out), "main"], {
        cwd: root, encoding: "utf8",
        env: { ...process.env, VIBE_PREOPEN_DIR: root, VIBE_BUILD_CACHE_DIR: cache, VIBE_FS_COMPILE: "1", VIBE_IMPORT_ABI: "raw", VIBE_RC: "0", VIBE_ARTIFACT_INPUT_TRACE_OUT: rel(tracePath), VIBE_ARTIFACT_INPUT_TRACE_NONCE: nonce, ...extraEnv },
      });
      const success = existsSync(out) && readFileSync(out).length > 0;
      if (success !== expectSuccess) fail(`${name} compile ${success ? "unexpectedly succeeded" : "failed"}: ${(result.stderr || result.stdout).trim()}`);
      if (!expectSuccess) {
        if (existsSync(tracePath)) fail(`${name} left a stale or partial sidecar`);
        return undefined;
      }
      if (!existsSync(tracePath)) fail(`${name} missing sidecar after successful compile`);
      return parseArtifactInputTrace(readFileSync(tracePath, "utf8"), nonce);
    };

    const rejectConflictingEarlyMode = (name, conflictingEnv) => {
      const out = join(project, `${name}.wasm`);
      const tracePath = join(project, `${name}.trace.json`);
      rmSync(out, { force: true }); writeFileSync(tracePath, "stale");
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, rel(join(project, "main.vibe")), rel(out), "main"], {
        cwd: root, encoding: "utf8",
        env: { ...process.env, VIBE_PREOPEN_DIR: root, VIBE_BUILD_CACHE_DIR: cache, VIBE_FS_COMPILE: "1", VIBE_IMPORT_ABI: "raw", VIBE_RC: "0", VIBE_ARTIFACT_INPUT_TRACE_OUT: rel(tracePath), VIBE_ARTIFACT_INPUT_TRACE_NONCE: `artifact-${name}`, ...conflictingEnv },
      });
      if (result.status === 0) fail(`${name} conflicting mode was accepted`);
      if (existsSync(tracePath)) fail(`${name} left a stale or partial sidecar`);
    };
    rejectConflictingEarlyMode("lsp", { VIBE_LSP: "1" });
    rejectConflictingEarlyMode("check-only", { VIBE_CHECK_ONLY: "1" });

    const cold = compile("cold", "artifact-cold");
    if (cold.persistent_lookup !== "miss") fail("cold compile was not a persistent miss");
    const warm = compile("warm", "artifact-warm");
    if (warm.persistent_lookup !== "hit") fail("warm compile was not a persistent hit");
    if (JSON.stringify(stableIdentity(cold)) !== JSON.stringify(stableIdentity(warm))) fail("cold/warm stable identities drifted");

    const config = compile("config", "artifact-config", true, { VIBE_CHECK_ERROR_ROW: "0", VIBE_DIAGNOSTICS_ALL: "1", VIBE_DEP_ORDER_SEED: "0007" });
    if (config.production_artifact_input_fingerprint !== warm.production_artifact_input_fingerprint) fail("config-only case changed production fingerprint");
    if (config.shadow_artifact_input_fingerprint === warm.shadow_artifact_input_fingerprint) fail("config-only case did not change shadow fingerprint");
    if (config.effective_config.dep_order_seed !== "7") fail("dep-order seed was not canonicalized");
    const configZero = compile("config-zero", "artifact-config-zero", true, { VIBE_DEP_ORDER_SEED: "invalid" });
    if (configZero.effective_config.dep_order_seed !== "0") fail("invalid dep-order seed was not canonicalized to zero");

    writeFileSync(join(project, "dep.vibe"), "export fn answer() -> Int { 40 }\nexport fn second() -> Int { 1 }\n");
    const edited = compile("edited", "artifact-edited");
    if (edited.persistent_lookup !== "miss") fail("dependency edit was not a persistent miss");
    if (edited.source_groups_fingerprint === warm.source_groups_fingerprint || edited.production_artifact_input_fingerprint === warm.production_artifact_input_fingerprint || edited.shadow_artifact_input_fingerprint === warm.shadow_artifact_input_fingerprint) fail("dependency content edit did not change identities");

    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nimport ./dep2.vibe { other }\nexport fn main() -> Int { answer() + other() }\n");
    const planned = compile("planned", "artifact-planned");
    if (planned.dependency_plan.fingerprint === edited.dependency_plan.fingerprint || planned.dependency_plan.module_count !== 3 || planned.dependency_plan.edge_occurrence_count !== 2) fail("dependency edge/plan change was not observed exactly");

    writeFileSync(join(project, "main.vibe"), "import ./dep2.vibe { other }\nimport ./dep.vibe { answer }\nexport fn main() -> Int { answer() + other() }\n");
    const reordered = compile("reordered", "artifact-reordered");
    if (reordered.dependency_plan.fingerprint === planned.dependency_plan.fingerprint || reordered.dependency_plan.module_count !== planned.dependency_plan.module_count || reordered.dependency_plan.edge_occurrence_count !== planned.dependency_plan.edge_occurrence_count) fail("dependency occurrence order was not preserved by the exact plan fingerprint");
    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nimport ./dep.vibe { second }\nexport fn main() -> Int { answer() + second() }\n");
    const duplicate = compile("duplicate", "artifact-duplicate");
    if (duplicate.dependency_plan.module_count !== 2 || duplicate.dependency_plan.edge_occurrence_count !== 2) fail("duplicate dependency occurrences were not preserved exactly");

    mkdirSync(join(resolutionRoot, "@trace", "context"), { recursive: true });
    writeFileSync(join(resolutionRoot, "@trace", "context", "index.vpkg"), "name = @trace/context\nversion = 0.0.1\ndeps = {}\n");
    const resolution = compile("resolution", "artifact-resolution", true, { VIBE_LIB: rel(resolutionRoot), VIBE_REQUIRE_PINS: "1" });
    if (resolution.resolution.env_seed === duplicate.resolution.env_seed || resolution.resolution.context_fingerprint === duplicate.resolution.context_fingerprint) fail("resolution seed/context change was not observed");
    if (resolution.production_artifact_input_fingerprint !== duplicate.production_artifact_input_fingerprint) fail("resolution-only case changed production fingerprint");
    if (resolution.shadow_artifact_input_fingerprint === duplicate.shadow_artifact_input_fingerprint) fail("resolution-only case did not change shadow fingerprint");

    writeFileSync(join(project, "main.vibe"), "export fn main( -> Int { 0 }\n");
    compile("failed", "artifact-failed", false);
    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nexport fn main() -> Int { answer() }\n");
    compile("no-nonce", "", false);
    console.log(JSON.stringify({ schema: 2, scenario: "fresh-stage2-artifact-input-trace", cold: cold.persistent_lookup, warm: warm.persistent_lookup, dependency_edit: edited.persistent_lookup }));
  } finally {
    if (process.env.VIBE_ARTIFACT_INPUT_TRACE_KEEP_TMP === "1") console.error(`artifact-input-trace-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) fail("usage: artifact_input_trace_oracle.mjs <stage2.wasm>");
  run(isAbsolute(process.argv[2]) ? process.argv[2] : resolve(process.cwd(), process.argv[2]));
}
