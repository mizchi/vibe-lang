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
  "artifact_input_fingerprint", "artifact_input_fingerprint_kind", "persistent_lookup",
].sort();

function fail(message) {
  throw new Error(`artifact-input-trace-oracle: ${message}`);
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  if (JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(keys)) fail(`${label} has unexpected or missing fields`);
}

/// Strict parser for successful artifact-input observations only.
export function parseArtifactInputTrace(text, expectedNonce = undefined) {
  let trace;
  try {
    trace = JSON.parse(text);
  } catch (error) {
    fail(`invalid JSON (${error.message})`);
  }
  exactKeys(trace, expectedKeys, "trace");
  if (trace.schema !== 1) fail(`unsupported schema ${JSON.stringify(trace.schema)}`);
  for (const key of ["run_nonce", "scope_disclaimer", "compile_lane", "persistent_artifact_kind", "source_groups_fingerprint", "source_groups_fingerprint_kind", "artifact_input_fingerprint", "artifact_input_fingerprint_kind", "persistent_lookup"]) {
    if (typeof trace[key] !== "string" || trace[key].length === 0) fail(`missing ${key}`);
  }
  if (expectedNonce !== undefined && trace.run_nonce !== expectedNonce) fail("run_nonce mismatch (stale sidecar)");
  if (trace.compile_lane !== "file_compile.persistent_pre_strip_wasi_cached_bump") fail("wrong compile lane");
  if (trace.persistent_artifact_kind !== "file-compile-wasi") fail("wrong persistent artifact kind");
  if (!trace.scope_disclaimer.includes("observation-only") || !trace.scope_disclaimer.includes("not a production cache key")) fail("missing scope disclaimer");
  exactKeys(trace.entry, ["mode", "name", "path"], "entry");
  for (const key of ["path", "name", "mode"]) {
    if (typeof trace.entry[key] !== "string" || trace.entry[key].length === 0) fail(`missing entry ${key}`);
  }
  if (trace.entry.mode !== "no-dce") fail("wrong entry mode");
  if (trace.source_groups_fingerprint_kind !== "build_source_groups_fingerprint(source_groups)") fail("dishonest source groups fingerprint kind");
  if (trace.artifact_input_fingerprint_kind !== "build_file_compile_wasi_artifact_fingerprint_from_group_fingerprint_for_entry_path(source_groups_fingerprint, entry_path, entry_name, mode)") fail("dishonest artifact input fingerprint kind");
  if (trace.persistent_lookup !== "hit" && trace.persistent_lookup !== "miss") fail("invalid persistent lookup");
  return trace;
}

function stableIdentity(trace) {
  return {
    compile_lane: trace.compile_lane,
    persistent_artifact_kind: trace.persistent_artifact_kind,
    entry: trace.entry,
    source_groups_fingerprint: trace.source_groups_fingerprint,
    source_groups_fingerprint_kind: trace.source_groups_fingerprint_kind,
    artifact_input_fingerprint: trace.artifact_input_fingerprint,
    artifact_input_fingerprint_kind: trace.artifact_input_fingerprint_kind,
  };
}

function run(stage2) {
  const runner = resolve(process.env.VIBE_RUNNER || join(root, "runtime/viberun/target/release/viberun"));
  const invoke = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  if (![stage2, runner, invoke].every(existsSync)) fail("missing stage2 compiler, runner, or host runner");
  const work = mkdtempSync(join(root, "_build/artifact-input-trace-"));
  const rel = (path) => relative(root, path);
  const project = join(work, "project");
  const cache = join(work, "cache");
  try {
    mkdirSync(project, { recursive: true });
    writeFileSync(join(project, "dep.vibe"), "export fn answer() -> Int { 41 }\n");
    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nexport fn main() -> Int { answer() + 1 }\n");
    const compile = (name, nonce, expectSuccess = true) => {
      const out = join(project, `${name}.wasm`);
      const tracePath = join(project, `${name}.trace.json`);
      rmSync(out, { force: true });
      writeFileSync(tracePath, "stale");
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, rel(join(project, "main.vibe")), rel(out), "main"], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_RUNNER: runner,
          VIBE_PREOPEN_DIR: root,
          VIBE_BUILD_CACHE_DIR: cache,
          VIBE_FS_COMPILE: "1",
          VIBE_IMPORT_ABI: "raw",
          VIBE_RC: "0",
          VIBE_ARTIFACT_INPUT_TRACE_OUT: rel(tracePath),
          VIBE_ARTIFACT_INPUT_TRACE_NONCE: nonce,
        },
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

    // The trace request must fail closed before modes that return before the
    // FS cached compile lane, and must remove a stale sidecar even for LSP
    // (which does not consume the ordinary input/output arguments).
    const rejectConflictingEarlyMode = (name, conflictingEnv) => {
      const out = join(project, `${name}.wasm`);
      const tracePath = join(project, `${name}.trace.json`);
      rmSync(out, { force: true });
      writeFileSync(tracePath, "stale");
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, rel(join(project, "main.vibe")), rel(out), "main"], {
        cwd: root,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_RUNNER: runner,
          VIBE_PREOPEN_DIR: root,
          VIBE_BUILD_CACHE_DIR: cache,
          VIBE_FS_COMPILE: "1",
          VIBE_IMPORT_ABI: "raw",
          VIBE_RC: "0",
          VIBE_ARTIFACT_INPUT_TRACE_OUT: rel(tracePath),
          VIBE_ARTIFACT_INPUT_TRACE_NONCE: `artifact-${name}`,
          ...conflictingEnv,
        },
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

    writeFileSync(join(project, "dep.vibe"), "export fn answer() -> Int { 40 }\n");
    const edited = compile("edited", "artifact-edited");
    if (edited.persistent_lookup !== "miss") fail("dependency edit was not a persistent miss");
    if (edited.source_groups_fingerprint === warm.source_groups_fingerprint || edited.artifact_input_fingerprint === warm.artifact_input_fingerprint) fail("dependency edit did not change artifact input identities");

    writeFileSync(join(project, "main.vibe"), "export fn main( -> Int { 0 }\n");
    compile("failed", "artifact-failed", false);
    writeFileSync(join(project, "main.vibe"), "import ./dep.vibe { answer }\nexport fn main() -> Int { answer() }\n");
    compile("no-nonce", "", false);
    console.log(JSON.stringify({ schema: 1, scenario: "fresh-stage2-artifact-input-trace", cold: cold.persistent_lookup, warm: warm.persistent_lookup, dependency_edit: edited.persistent_lookup }));
  } finally {
    if (process.env.VIBE_ARTIFACT_INPUT_TRACE_KEEP_TMP === "1") console.error(`artifact-input-trace-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) fail("usage: artifact_input_trace_oracle.mjs <stage2.wasm>");
  run(isAbsolute(process.argv[2]) ? process.argv[2] : resolve(process.cwd(), process.argv[2]));
}
