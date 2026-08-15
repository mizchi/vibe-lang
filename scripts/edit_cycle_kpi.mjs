#!/usr/bin/env node
// Minimal user-visible incremental-build baseline.
//
//   node scripts/edit_cycle_kpi.mjs <stage2.wasm> [out.jsonl]
//
// The benchmark copies bench/incremental/edit_cycle into a temporary project,
// uses one isolated persistent cache per repetition, and never edits tracked
// sources or generated compiler bundles. It measures the current one-shot
// `vibe check` behavior and records its opt-in db_typecheck_fs work counters.

import { createHash, randomUUID } from "node:crypto";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const telemetryKeys = [
  "modules_planned",
  "modules_rechecked",
  "modules_reused",
  "parse_operations",
  "modules_failed_or_blocked",
  "current_source_parse_executions",
  "checker_executions",
  "modules_reused_conservative_fingerprint",
  "modules_reused_dependency_transport_env",
];
const hostFsScopeKeys = [
  "schema",
  "version",
  "nonce",
  "read_file_calls",
  "read_file_returned_bytes",
  "read_bytes_calls",
  "read_bytes_returned_bytes",
  "stat_token_calls",
  "exists_calls",
];
const hostFsScopeCounterKeys = hostFsScopeKeys.slice(3);
const ingestionFingerprintKeys = [
  "schema",
  "version",
  "nonce",
  "source_read_calls",
  "source_read_string_units",
  "hash_calls",
  "hash_input_string_units",
  "stamp_probes",
  "stamp_hits",
  "stamp_misses",
  "stamp_malformed",
  "stamp_text_units_read",
  "stamp_publications",
];
const ingestionFingerprintCounterKeys = ingestionFingerprintKeys.slice(3);

export const editCycleRecordSchema = "edit_cycle_kpi";
export const editCycleRecordVersion = 1;
export const editCycleCaseDefinitions = Object.freeze({
  cold: Object.freeze({ edit_kind: "none", cache_state: "empty" }),
  exact_noop: Object.freeze({ edit_kind: "none", cache_state: "preserved" }),
  comment_edit: Object.freeze({ edit_kind: "non_semantic", cache_state: "preserved" }),
  private_body_edit: Object.freeze({ edit_kind: "implementation", cache_state: "preserved" }),
  public_interface_edit: Object.freeze({ edit_kind: "interface", cache_state: "preserved" }),
});
export const editCycleCases = Object.freeze(Object.keys(editCycleCaseDefinitions));
export const editCycleModes = Object.freeze({
  persistent_ingestion_stamp: "disabled",
  typing_dependency_env_reuse: "default-on",
  invalidation_trace: "disabled",
  compilation: "check-only",
});
export const editCycleWorkScopes = Object.freeze({
  read_bytes: "host_fs_scope.all_host_import_returned_bytes",
  hash_calls: "ingestion_fingerprint.fingerprint_file_fs_hash_calls",
  parsed_files: "incremental_typecheck.typedb_current_source_parse_misses",
  checked_modules: "incremental_typecheck.checker_executions",
  codegen_modules: "check_endpoint.none",
});

/// Apply benchmark mode authority after ambient process.env. Empty strings are
/// deliberate: the CLI treats these optional controls as absent. Keeping this
/// helper exported makes ambient-mode isolation directly testable.
export function pinEditCycleModes(env) {
  return {
    ...env,
    VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP: "",
    VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: "",
    VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "",
    VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: "",
    VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "",
  };
}

export function parseEditCycleRunCount(rawValue) {
  const text = rawValue === undefined || rawValue === "" ? "3" : rawValue;
  if (typeof text !== "string" || !/^[1-9][0-9]*$/u.test(text)) {
    throw new Error(`VIBE_EDIT_CYCLE_RUNS must be a positive decimal safe integer, got ${rawValue}`);
  }
  const runs = Number(text);
  if (!Number.isSafeInteger(runs)) {
    throw new Error(`VIBE_EDIT_CYCLE_RUNS must be a positive decimal safe integer, got ${rawValue}`);
  }
  return runs;
}

export function assertDisabledIngestionStamps(telemetry, source = "ingestion fingerprint telemetry") {
  for (const key of [
    "stamp_probes",
    "stamp_hits",
    "stamp_misses",
    "stamp_malformed",
    "stamp_text_units_read",
    "stamp_publications",
  ]) {
    if (telemetry[key] !== 0) throw new Error(`${source}: ${key} must be 0 when ingestion stamps are disabled`);
  }
}

export function buildEditCycleWorkSummary(incrementalTypecheck, ingestionFingerprint, hostFsScope) {
  const readBytes = hostFsScope.read_file_returned_bytes + hostFsScope.read_bytes_returned_bytes;
  if (!Number.isSafeInteger(readBytes)) {
    throw new Error("edit-cycle KPI work summary: read_bytes exceeds the safe integer range");
  }
  return {
    read_bytes: readBytes,
    hash_calls: ingestionFingerprint.hash_calls,
    parsed_files: incrementalTypecheck.current_source_parse_executions,
    checked_modules: incrementalTypecheck.checker_executions,
    codegen_modules: 0,
  };
}

/// Parse and validate the compiler-owned incremental typecheck sidecar.
/// Kept exported so the structural contract has a focused Node regression test
/// without needing to run a full wasm compiler invocation.
export function parseIncrementalTelemetry(text, source = "incremental telemetry") {
  let telemetry;
  try {
    telemetry = JSON.parse(text);
  } catch (error) {
    throw new Error(`${source}: invalid JSON (${error.message})`);
  }
  if (telemetry === null || typeof telemetry !== "object" || Array.isArray(telemetry)) {
    throw new Error(`${source}: expected a JSON object`);
  }
  if (telemetry.schema !== 2) {
    throw new Error(`${source}: unsupported schema ${JSON.stringify(telemetry.schema)}`);
  }
  const exactKeys = ["schema", ...telemetryKeys];
  if (Object.keys(telemetry).length !== exactKeys.length || exactKeys.some((key) => !Object.hasOwn(telemetry, key))) {
    throw new Error(`${source}: expected exactly the incremental telemetry v2 fields`);
  }
  for (const key of telemetryKeys) {
    if (!Number.isSafeInteger(telemetry[key]) || telemetry[key] < 0) {
      throw new Error(`${source}: ${key} must be a non-negative safe integer`);
    }
  }
  if (
    telemetry.modules_rechecked
      + telemetry.modules_reused
      + telemetry.modules_failed_or_blocked
      !== telemetry.modules_planned
  ) {
    throw new Error(
      `${source}: modules_rechecked + modules_reused + modules_failed_or_blocked must equal modules_planned`,
    );
  }
  if (
    telemetry.modules_reused_conservative_fingerprint
      + telemetry.modules_reused_dependency_transport_env
      !== telemetry.modules_reused
  ) {
    throw new Error(`${source}: reuse-class counters must sum to modules_reused`);
  }
  return telemetry;
}

/// Parse compiler-owned fingerprint-helper telemetry. This is intentionally
/// not host_fs_scope: its source/hash unit fields are String::length units,
/// while host_fs_scope remains aggregate runner-observed raw bytes.
export function parseIngestionFingerprintTelemetry(text, expectedNonce, source = "ingestion fingerprint telemetry") {
  let telemetry;
  try {
    telemetry = JSON.parse(text);
  } catch (error) {
    throw new Error(`${source}: invalid JSON (${error.message})`);
  }
  if (telemetry === null || typeof telemetry !== "object" || Array.isArray(telemetry)) {
    throw new Error(`${source}: expected a JSON object`);
  }
  const actualKeys = Object.keys(telemetry).sort();
  const expectedKeys = [...ingestionFingerprintKeys].sort();
  if (actualKeys.length !== expectedKeys.length || actualKeys.some((key, index) => key !== expectedKeys[index])) {
    throw new Error(`${source}: expected exactly the ingestion_fingerprint v1 fields`);
  }
  if (telemetry.schema !== "ingestion_fingerprint" || telemetry.version !== 1) {
    throw new Error(`${source}: unsupported ingestion_fingerprint schema/version`);
  }
  if (typeof telemetry.nonce !== "string" || telemetry.nonce.length === 0 || /\p{Cc}/u.test(telemetry.nonce)) {
    throw new Error(`${source}: nonce must be non-empty and contain no control characters`);
  }
  if (telemetry.nonce !== expectedNonce) throw new Error(`${source}: nonce mismatch`);
  for (const key of ingestionFingerprintCounterKeys) {
    if (!Number.isSafeInteger(telemetry[key]) || telemetry[key] < 0) {
      throw new Error(`${source}: ${key} must be a non-negative safe integer`);
    }
  }
  if (telemetry.stamp_probes !== telemetry.stamp_hits + telemetry.stamp_misses + telemetry.stamp_malformed) {
    throw new Error(`${source}: stamp_probes must equal stamp_hits + stamp_misses + stamp_malformed`);
  }
  if (telemetry.hash_calls !== telemetry.source_read_calls) {
    throw new Error(`${source}: hash_calls must equal source_read_calls`);
  }
  if (telemetry.hash_input_string_units !== telemetry.source_read_string_units) {
    throw new Error(`${source}: hash_input_string_units must equal source_read_string_units`);
  }
  return telemetry;
}

/// Parse the runner-owned host filesystem import sidecar. This is intentionally
/// separate from compiler-owned incremental typecheck telemetry: its schema is
/// `host_fs_scope`, and its counters are import boundaries, not source hashes.
export function parseHostFsScopeTelemetry(text, expectedNonce, source = "host filesystem telemetry") {
  let telemetry;
  try {
    telemetry = JSON.parse(text);
  } catch (error) {
    throw new Error(`${source}: invalid JSON (${error.message})`);
  }
  if (telemetry === null || typeof telemetry !== "object" || Array.isArray(telemetry)) {
    throw new Error(`${source}: expected a JSON object`);
  }
  const actualKeys = Object.keys(telemetry).sort();
  const expectedKeys = [...hostFsScopeKeys].sort();
  if (actualKeys.length !== expectedKeys.length || actualKeys.some((key, index) => key !== expectedKeys[index])) {
    throw new Error(`${source}: expected exactly the host_fs_scope v1 fields`);
  }
  if (telemetry.schema !== "host_fs_scope" || telemetry.version !== 1) {
    throw new Error(`${source}: unsupported host_fs_scope schema/version`);
  }
  if (
    typeof telemetry.nonce !== "string"
    || telemetry.nonce.length === 0
    || /\p{Cc}/u.test(telemetry.nonce)
  ) {
    throw new Error(`${source}: nonce must be non-empty and contain no control characters`);
  }
  if (telemetry.nonce !== expectedNonce) {
    throw new Error(`${source}: nonce mismatch`);
  }
  for (const key of hostFsScopeCounterKeys) {
    if (!Number.isSafeInteger(telemetry[key]) || telemetry[key] < 0) {
      throw new Error(`${source}: ${key} must be a non-negative safe integer`);
    }
  }
  return telemetry;
}

function main() {
  const stageArg = process.argv[2];
  const outputArg = process.argv[3];
  if (!stageArg) {
    console.error("usage: node scripts/edit_cycle_kpi.mjs <stage2.wasm> [out.jsonl]");
    process.exit(2);
  }

  const stage2 = isAbsolute(stageArg) ? stageArg : resolve(process.cwd(), stageArg);
  const runner = resolve(process.env.VIBE_RUNNER || join(root, "runtime/viberun/target/release/viberun"));
  const launcher = join(root, "runtime/vibe");
  const fixture = join(root, "bench/incremental/edit_cycle");
  for (const path of [stage2, runner, launcher, fixture]) {
    if (!existsSync(path)) {
      console.error(`edit-cycle-kpi: missing prerequisite: ${path}`);
      process.exit(2);
    }
  }

  let runs;
  try {
    runs = parseEditCycleRunCount(process.env.VIBE_EDIT_CYCLE_RUNS);
  } catch (error) {
    console.error(`edit-cycle-kpi: ${error.message}`);
    process.exit(2);
  }

  const compilerSha = createHash("sha256").update(readFileSync(stage2)).digest("hex");
  const runnerSha = createHash("sha256").update(readFileSync(runner)).digest("hex");
  const fixtureSha = createHash("sha256")
    .update("entry.vibe\0")
    .update(readFileSync(join(fixture, "entry.vibe")))
    .update("\0leaf.vibe\0")
    .update(readFileSync(join(fixture, "leaf.vibe")))
    .digest("hex");
  const work = mkdtempSync(join(tmpdir(), "vibe-edit-cycle-kpi-"));
  const records = [];

  function check(project, cache, run, caseName, editKind, cacheState) {
    const telemetryPath = join(project, ".vibe-incremental-telemetry.json");
    const hostFsScopePath = join(project, ".vibe-host-fs-scope.json");
    const hostFsScopeNonce = randomUUID();
    const ingestionTelemetryPath = join(project, ".vibe-ingestion-telemetry.json");
    const ingestionTelemetryNonce = randomUUID();
    rmSync(telemetryPath, { force: true });
    rmSync(ingestionTelemetryPath, { force: true });
    // The runner also removes this before guest execution; do it here too so
    // a runner regression cannot turn a stale sidecar into a benchmark result.
    rmSync(hostFsScopePath, { force: true });
    const start = process.hrtime.bigint();
    const result = spawnSync(launcher, ["check", "entry.vibe"], {
      cwd: project,
      encoding: "utf8",
      env: {
        ...pinEditCycleModes(process.env),
        VIBE_BUILD_CACHE_DIR: cache,
        VIBE_CLI_CWASM: "",
        VIBE_CLI_WASM: stage2,
        VIBE_HOME: join(work, "home"),
        VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryPath,
        VIBE_INGESTION_TELEMETRY_OUT: ingestionTelemetryPath,
        VIBE_INGESTION_TELEMETRY_NONCE: ingestionTelemetryNonce,
        VIBE_HOST_FS_SCOPE_OUT: hostFsScopePath,
        VIBE_HOST_FS_SCOPE_NONCE: hostFsScopeNonce,
        VIBE_PREOPEN_DIR: project,
        VIBE_RUNNER: runner,
      },
    });
    const wallMs = Number(process.hrtime.bigint() - start) / 1_000_000;
    if (result.status !== 0) {
      console.error(`edit-cycle-kpi: ${caseName} failed (run ${run})`);
      if (result.stdout) console.error(result.stdout.trim());
      if (result.stderr) console.error(result.stderr.trim());
      process.exit(1);
    }
    if (!existsSync(telemetryPath)) {
      throw new Error(`edit-cycle-kpi: ${caseName} omitted incremental telemetry sidecar`);
    }
    const telemetry = parseIncrementalTelemetry(
      readFileSync(telemetryPath, "utf8"),
      `edit-cycle-kpi: ${caseName} telemetry`,
    );
    if (telemetry.modules_planned < 1) {
      throw new Error(`edit-cycle-kpi: ${caseName} telemetry planned no modules`);
    }
    if (!existsSync(ingestionTelemetryPath)) {
      throw new Error(`edit-cycle-kpi: ${caseName} omitted ingestion fingerprint telemetry sidecar`);
    }
    const ingestionFingerprint = parseIngestionFingerprintTelemetry(
      readFileSync(ingestionTelemetryPath, "utf8"),
      ingestionTelemetryNonce,
      `edit-cycle-kpi: ${caseName} ingestion fingerprint telemetry`,
    );
    assertDisabledIngestionStamps(
      ingestionFingerprint,
      `edit-cycle-kpi: ${caseName} ingestion fingerprint telemetry`,
    );
    if (!existsSync(hostFsScopePath)) {
      throw new Error(`edit-cycle-kpi: ${caseName} omitted host filesystem telemetry sidecar`);
    }
    const hostFsScope = parseHostFsScopeTelemetry(
      readFileSync(hostFsScopePath, "utf8"),
      hostFsScopeNonce,
      `edit-cycle-kpi: ${caseName} host filesystem telemetry`,
    );
    records.push({
      schema: editCycleRecordSchema,
      version: editCycleRecordVersion,
      benchmark: "user-edit-cycle-check",
      compiler_sha256: compilerSha,
      compiler_file: basename(stage2),
      runner_sha256: runnerSha,
      fixture_sha256: fixtureSha,
      run,
      case: caseName,
      edit_kind: editKind,
      cache_state: cacheState,
      process_mode: "one-shot",
      endpoint: "check-command-complete",
      modes: editCycleModes,
      work_scopes: editCycleWorkScopes,
      work_summary: buildEditCycleWorkSummary(telemetry, ingestionFingerprint, hostFsScope),
      incremental_typecheck: telemetry,
      ingestion_fingerprint: ingestionFingerprint,
      host_fs_scope: hostFsScope,
      wall_ms: Number(wallMs.toFixed(3)),
      success: true,
    });
  }

  try {
    for (let run = 1; run <= runs; run += 1) {
      const runDir = join(work, `run-${run}`);
      const project = join(runDir, "project");
      const cache = join(runDir, "cache");
      mkdirSync(cache, { recursive: true });
      cpSync(fixture, project, { recursive: true });

      check(project, cache, run, "cold", "none", "empty");
      check(project, cache, run, "exact_noop", "none", "preserved");

      const leaf = join(project, "leaf.vibe");
      writeFileSync(leaf, `${readFileSync(leaf, "utf8")}\n// non-semantic edit\n`);
      check(project, cache, run, "comment_edit", "non_semantic", "preserved");

      const privateBody = readFileSync(leaf, "utf8").replace("x + 1", "x + 2");
      if (!privateBody.includes("x + 2")) throw new Error("private edit fixture drift");
      writeFileSync(leaf, privateBody);
      check(project, cache, run, "private_body_edit", "implementation", "preserved");

      writeFileSync(
        leaf,
        'export fn leaf_value(x: Int) -> String {\n  "changed"\n}\n',
      );
      check(project, cache, run, "public_interface_edit", "interface", "preserved");
    }

    const jsonl = `${records.map((record) => JSON.stringify(record)).join("\n")}\n`;
    if (outputArg) {
      const output = isAbsolute(outputArg) ? outputArg : resolve(process.cwd(), outputArg);
      mkdirSync(dirname(output), { recursive: true });
      writeFileSync(output, jsonl);
      console.error(`edit-cycle-kpi: wrote ${output}`);
    } else {
      process.stdout.write(jsonl);
    }

    for (const caseName of [...new Set(records.map((record) => record.case))]) {
      const values = records
        .filter((record) => record.case === caseName)
        .map((record) => record.wall_ms)
        .sort((left, right) => left - right);
      const median = values[Math.floor(values.length / 2)];
      const p95 = values[Math.max(0, Math.ceil(values.length * 0.95) - 1)];
      console.error(
        `edit-cycle-kpi: ${caseName} median_ms=${median.toFixed(3)} p95_ms=${p95.toFixed(3)} runs=${values.length}`,
      );
    }
  } finally {
    if (process.env.VIBE_EDIT_CYCLE_KEEP_TMP === "1") {
      console.error(`edit-cycle-kpi: kept ${work}`);
    } else {
      rmSync(work, { recursive: true, force: true });
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
