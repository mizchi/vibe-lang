#!/usr/bin/env node
// Strict before/after comparator for scripts/edit_cycle_kpi.mjs JSONL.
// It validates mode and scope authority before computing deterministic deltas.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  assertDisabledIngestionStamps,
  buildEditCycleWorkSummary,
  editCycleCaseDefinitions,
  editCycleCases,
  editCycleModes,
  editCycleRecordSchema,
  editCycleRecordVersion,
  editCycleWorkScopes,
  ingestionPipelineCounterKeys,
  parseHostFsScopeTelemetry,
  parseIngestionPipelineTelemetry,
  parseIncrementalTelemetry,
  parseIngestionFingerprintTelemetry,
} from "./edit_cycle_kpi.mjs";

const sha256Pattern = /^[0-9a-f]{64}$/;
const workKeys = [
  "read_bytes",
  "hash_calls",
  "parsed_files",
  "checked_modules",
  "codegen_modules",
];
const recordKeys = [
  "schema",
  "version",
  "benchmark",
  "compiler_sha256",
  "compiler_file",
  "runner_sha256",
  "fixture_sha256",
  "run",
  "case",
  "edit_kind",
  "cache_state",
  "process_mode",
  "endpoint",
  "modes",
  "work_scopes",
  "work_summary",
  "incremental_typecheck",
  "ingestion_fingerprint",
  "ingestion_pipeline",
  "host_fs_scope",
  "wall_ms",
  "success",
];

function assertExactKeys(value, keys, source) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${source}: expected a JSON object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${source}: unexpected fields`);
  }
}

function assertExactObject(value, expected, source) {
  assertExactKeys(value, Object.keys(expected), source);
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (value[key] !== expectedValue) {
      throw new Error(`${source}: ${key} must be ${JSON.stringify(expectedValue)}`);
    }
  }
}

export function parseEditCycleRecord(value, source = "edit-cycle record") {
  assertExactKeys(value, recordKeys, source);
  if (value.schema !== editCycleRecordSchema || value.version !== editCycleRecordVersion) {
    throw new Error(
      `${source}: unsupported outer schema/version ${JSON.stringify(value.schema)}/${JSON.stringify(value.version)}`,
    );
  }
  if (value.benchmark !== "user-edit-cycle-check") {
    throw new Error(`${source}: unsupported benchmark ${JSON.stringify(value.benchmark)}`);
  }
  for (const key of ["compiler_sha256", "runner_sha256", "fixture_sha256"]) {
    if (typeof value[key] !== "string" || !sha256Pattern.test(value[key])) {
      throw new Error(`${source}: ${key} must be a lowercase SHA-256 hex digest`);
    }
  }
  if (typeof value.compiler_file !== "string" || value.compiler_file.length === 0) {
    throw new Error(`${source}: compiler_file must be non-empty`);
  }
  if (!Number.isSafeInteger(value.run) || value.run < 1) {
    throw new Error(`${source}: run must be a positive safe integer`);
  }
  if (typeof value.case !== "string" || !Object.hasOwn(editCycleCaseDefinitions, value.case)) {
    throw new Error(`${source}: unsupported case ${JSON.stringify(value.case)}`);
  }
  const expectedCase = editCycleCaseDefinitions[value.case];
  for (const key of ["edit_kind", "cache_state"]) {
    if (value[key] !== expectedCase[key]) {
      throw new Error(`${source}: ${value.case}.${key} must be ${JSON.stringify(expectedCase[key])}`);
    }
  }
  if (value.process_mode !== "one-shot") {
    throw new Error(`${source}: process_mode must be one-shot`);
  }
  if (value.endpoint !== "check-command-complete") {
    throw new Error(`${source}: endpoint must be check-command-complete`);
  }
  assertExactObject(value.modes, editCycleModes, `${source}: modes`);
  assertExactObject(value.work_scopes, editCycleWorkScopes, `${source}: work_scopes`);
  assertExactKeys(value.work_summary, workKeys, `${source}: work_summary`);
  for (const key of workKeys) {
    if (!Number.isSafeInteger(value.work_summary[key]) || value.work_summary[key] < 0) {
      throw new Error(`${source}: work_summary.${key} must be a non-negative safe integer`);
    }
  }
  if (value.work_summary.codegen_modules !== 0) {
    throw new Error(`${source}: check endpoint requires codegen_modules to be 0`);
  }
  if (!Number.isFinite(value.wall_ms) || value.wall_ms < 0) {
    throw new Error(`${source}: wall_ms must be a non-negative finite number`);
  }
  if (value.success !== true) {
    throw new Error(`${source}: success must be true`);
  }

  const incremental = parseIncrementalTelemetry(
    JSON.stringify(value.incremental_typecheck),
    `${source}: incremental_typecheck`,
  );
  const ingestion = parseIngestionFingerprintTelemetry(
    JSON.stringify(value.ingestion_fingerprint),
    value.ingestion_fingerprint?.nonce,
    `${source}: ingestion_fingerprint`,
  );
  assertDisabledIngestionStamps(ingestion, `${source}: ingestion_fingerprint`);
  const pipeline = parseIngestionPipelineTelemetry(
    JSON.stringify(value.ingestion_pipeline),
    value.ingestion_pipeline?.nonce,
    `${source}: ingestion_pipeline`,
  );
  if (pipeline.final_semantic_source_parse_executions !== incremental.current_source_parse_executions) {
    throw new Error(`${source}: ingestion pipeline final semantic parses disagree with schema 2`);
  }
  const hostFs = parseHostFsScopeTelemetry(
    JSON.stringify(value.host_fs_scope),
    value.host_fs_scope?.nonce,
    `${source}: host_fs_scope`,
  );
  const derived = buildEditCycleWorkSummary(incremental, ingestion, hostFs);
  for (const key of workKeys) {
    if (value.work_summary[key] !== derived[key]) {
      throw new Error(`${source}: work_summary.${key} does not match scoped telemetry`);
    }
  }
  return value;
}

export function parseEditCycleJsonl(text, source = "edit-cycle JSONL") {
  const lines = text.split(/\r?\n/u).filter((line) => line.length > 0);
  if (lines.length === 0) throw new Error(`${source}: expected at least one record`);
  return lines.map((line, index) => {
    let value;
    try {
      value = JSON.parse(line);
    } catch (error) {
      throw new Error(`${source}:${index + 1}: invalid JSON (${error.message})`);
    }
    return parseEditCycleRecord(value, `${source}:${index + 1}`);
  });
}

function identityOf(records, source) {
  const first = records[0];
  const fixed = {
    schema: first.schema,
    version: first.version,
    benchmark: first.benchmark,
    fixture_sha256: first.fixture_sha256,
    runner_sha256: first.runner_sha256,
    process_mode: first.process_mode,
    endpoint: first.endpoint,
    modes: first.modes,
    work_scopes: first.work_scopes,
  };
  const seen = new Set();
  for (const record of records) {
    for (const key of ["schema", "version", "benchmark", "fixture_sha256", "runner_sha256", "process_mode", "endpoint"]) {
      if (record[key] !== fixed[key]) throw new Error(`${source}: mixed ${key}`);
    }
    assertExactObject(record.modes, fixed.modes, `${source}: mixed modes`);
    assertExactObject(record.work_scopes, fixed.work_scopes, `${source}: mixed work_scopes`);
    const key = `${record.case}\0${record.run}`;
    if (seen.has(key)) throw new Error(`${source}: duplicate case/run ${record.case}/${record.run}`);
    seen.add(key);
  }
  const actualCases = [...new Set(records.map((record) => record.case))].sort();
  const expectedCases = [...editCycleCases].sort();
  if (actualCases.length !== expectedCases.length || actualCases.some((value, index) => value !== expectedCases[index])) {
    throw new Error(`${source}: case set must be exactly ${editCycleCases.join(", ")}`);
  }
  const runs = [...new Set(records.map((record) => record.run))].sort((left, right) => left - right);
  for (let index = 0; index < runs.length; index += 1) {
    if (runs[index] !== index + 1) throw new Error(`${source}: runs must be contiguous starting at 1`);
    for (const caseName of editCycleCases) {
      if (!seen.has(`${caseName}\0${runs[index]}`)) {
        throw new Error(`${source}: incomplete case/run matrix at ${caseName}/${runs[index]}`);
      }
    }
  }
  const compilerShas = [...new Set(records.map((record) => record.compiler_sha256))];
  if (compilerShas.length !== 1) throw new Error(`${source}: mixed compiler_sha256`);
  return { ...fixed, compiler_sha256: compilerShas[0], runs };
}

function stableCaseCounters(records, caseName, field, keys, source) {
  const rows = records.filter((record) => record.case === caseName);
  if (rows.length === 0) throw new Error(`${source}: missing case ${caseName}`);
  const first = rows[0][field];
  for (const row of rows.slice(1)) {
    for (const key of keys) {
      if (row[field][key] !== first[key]) {
        throw new Error(`${source}: nondeterministic ${caseName}.${field}.${key} across repetitions`);
      }
    }
  }
  return first;
}

function stableCaseWork(records, caseName, source) {
  const rows = records.filter((record) => record.case === caseName);
  if (rows.length === 0) throw new Error(`${source}: missing case ${caseName}`);
  const first = rows[0].work_summary;
  for (const row of rows.slice(1)) {
    for (const key of workKeys) {
      if (row.work_summary[key] !== first[key]) {
        throw new Error(`${source}: nondeterministic ${caseName}.${key} across repetitions`);
      }
    }
  }
  return first;
}

export function compareEditCycleRecords(beforeRecords, afterRecords) {
  if (!Array.isArray(beforeRecords) || beforeRecords.length === 0) throw new Error("before: expected records");
  if (!Array.isArray(afterRecords) || afterRecords.length === 0) throw new Error("after: expected records");
  beforeRecords.forEach((record, index) => parseEditCycleRecord(record, `before:${index + 1}`));
  afterRecords.forEach((record, index) => parseEditCycleRecord(record, `after:${index + 1}`));
  const beforeIdentity = identityOf(beforeRecords, "before");
  const afterIdentity = identityOf(afterRecords, "after");
  for (const key of ["schema", "version", "benchmark", "fixture_sha256", "runner_sha256", "process_mode", "endpoint"]) {
    if (beforeIdentity[key] !== afterIdentity[key]) throw new Error(`comparison: mismatched ${key}`);
  }
  if (
    beforeIdentity.runs.length !== afterIdentity.runs.length
    || beforeIdentity.runs.some((run, index) => run !== afterIdentity.runs[index])
  ) throw new Error("comparison: mismatched run topology");
  assertExactObject(afterIdentity.modes, beforeIdentity.modes, "comparison: mismatched modes");
  assertExactObject(afterIdentity.work_scopes, beforeIdentity.work_scopes, "comparison: mismatched work_scopes");

  return {
    schema: "incremental_phase_summary",
    version: 2,
    benchmark: beforeIdentity.benchmark,
    fixture_sha256: beforeIdentity.fixture_sha256,
    runner_sha256: beforeIdentity.runner_sha256,
    process_mode: beforeIdentity.process_mode,
    endpoint: beforeIdentity.endpoint,
    runs: beforeIdentity.runs,
    modes: beforeIdentity.modes,
    work_scopes: beforeIdentity.work_scopes,
    before_compiler_sha256: beforeIdentity.compiler_sha256,
    after_compiler_sha256: afterIdentity.compiler_sha256,
    cases: editCycleCases.map((caseName) => {
      const before = stableCaseWork(beforeRecords, caseName, "before");
      const after = stableCaseWork(afterRecords, caseName, "after");
      const beforePipeline = stableCaseCounters(beforeRecords, caseName, "ingestion_pipeline", ingestionPipelineCounterKeys, "before");
      const afterPipeline = stableCaseCounters(afterRecords, caseName, "ingestion_pipeline", ingestionPipelineCounterKeys, "after");
      return {
        case: caseName,
        before,
        after,
        delta: Object.fromEntries(workKeys.map((key) => [key, after[key] - before[key]])),
        ingestion_pipeline: {
          before: Object.fromEntries(ingestionPipelineCounterKeys.map((key) => [key, beforePipeline[key]])),
          after: Object.fromEntries(ingestionPipelineCounterKeys.map((key) => [key, afterPipeline[key]])),
          delta: Object.fromEntries(ingestionPipelineCounterKeys.map((key) => [key, afterPipeline[key] - beforePipeline[key]])),
        },
      };
    }),
  };
}

function main() {
  const [beforeArg, afterArg, outputArg] = process.argv.slice(2);
  if (!beforeArg || !afterArg) {
    console.error("usage: node scripts/incremental_phase_summary.mjs <before.jsonl> <after.jsonl> [out.json]");
    process.exit(2);
  }
  const load = (arg, label) => {
    const path = isAbsolute(arg) ? arg : resolve(process.cwd(), arg);
    return parseEditCycleJsonl(readFileSync(path, "utf8"), label);
  };
  const summary = compareEditCycleRecords(load(beforeArg, "before"), load(afterArg, "after"));
  const json = `${JSON.stringify(summary, null, 2)}\n`;
  if (outputArg) {
    const output = isAbsolute(outputArg) ? outputArg : resolve(process.cwd(), outputArg);
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, json);
  } else {
    process.stdout.write(json);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
