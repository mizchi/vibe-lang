import assert from "node:assert/strict";
import test from "node:test";

import {
  buildEditCycleWorkSummary,
  editCycleCaseDefinitions,
  editCycleCases,
  editCycleModes,
  editCycleRecordSchema,
  editCycleRecordVersion,
  editCycleWorkScopes,
} from "./edit_cycle_kpi.mjs";
import {
  compareEditCycleRecords,
  parseEditCycleJsonl,
  parseEditCycleRecord,
} from "./incremental_phase_summary.mjs";

const sha = (digit) => digit.repeat(64);

function makeRecord(caseName, overrides = {}) {
  const incremental = {
    schema: 2,
    modules_planned: 2,
    modules_rechecked: 1,
    modules_reused: 1,
    parse_operations: 1,
    modules_failed_or_blocked: 0,
    current_source_parse_executions: 1,
    checker_executions: 1,
    modules_reused_conservative_fingerprint: 0,
    modules_reused_dependency_transport_env: 1,
  };
  const ingestion = {
    schema: "ingestion_fingerprint",
    version: 1,
    nonce: `nonce-${caseName}`,
    source_read_calls: 2,
    source_read_string_units: 20,
    hash_calls: 2,
    hash_input_string_units: 20,
    stamp_probes: 0,
    stamp_hits: 0,
    stamp_misses: 0,
    stamp_malformed: 0,
    stamp_text_units_read: 0,
    stamp_publications: 0,
  };
  const pipeline = {
    schema: "ingestion_pipeline",
    version: 1,
    nonce: `pipeline-${caseName}`,
    source_list_cache_probes: 1,
    source_list_cache_hits: 0,
    source_list_cache_misses: 1,
    source_group_cache_probes: 1,
    source_group_cache_hits: 0,
    source_group_cache_misses: 1,
    source_list_group_reconstruction_attempts: 1,
    source_list_group_reconstruction_hits: 0,
    source_list_group_reconstruction_misses: 1,
    cold_collect_all_sources_executions: 1,
    module_header_cache_probes: 1,
    module_header_cache_hits: 0,
    module_header_cache_misses: 1,
    module_header_parse_scan_executions: 1,
    entry_precheck_parse_executions: 1,
    final_semantic_source_parse_executions: 1,
    linked_validation_source_parse_executions: 1,
    warning_entry_parse_executions: 1,
  };
  const hostFs = {
    schema: "host_fs_scope",
    version: 1,
    nonce: `nonce-${caseName}`,
    read_file_calls: 3,
    read_file_returned_bytes: 30,
    read_bytes_calls: 4,
    read_bytes_returned_bytes: 40,
    stat_token_calls: 5,
    exists_calls: 6,
  };
  return {
    schema: editCycleRecordSchema,
    version: editCycleRecordVersion,
    benchmark: "user-edit-cycle-check",
    compiler_sha256: sha("1"),
    compiler_file: "stage2.wasm",
    runner_sha256: sha("2"),
    fixture_sha256: sha("3"),
    run: 1,
    case: caseName,
    edit_kind: editCycleCaseDefinitions[caseName].edit_kind,
    cache_state: editCycleCaseDefinitions[caseName].cache_state,
    process_mode: "one-shot",
    endpoint: "check-command-complete",
    modes: { ...editCycleModes },
    work_scopes: { ...editCycleWorkScopes },
    work_summary: buildEditCycleWorkSummary(incremental, ingestion, hostFs),
    incremental_typecheck: incremental,
    ingestion_fingerprint: ingestion,
    ingestion_pipeline: pipeline,
    host_fs_scope: hostFs,
    wall_ms: 12.5,
    success: true,
    ...overrides,
  };
}

const makeSet = (overrides = {}, runs = [1]) => runs.flatMap(
  (run) => editCycleCases.map((caseName) => makeRecord(caseName, { run, ...overrides })),
);

function clone(value) {
  return structuredClone(value);
}

test("phase summary emits scoped deterministic deltas", () => {
  const before = makeSet();
  const after = clone(before);
  for (const record of after) {
    record.compiler_sha256 = sha("4");
    record.host_fs_scope.read_bytes_returned_bytes += 5;
    record.work_summary.read_bytes += 5;
    record.incremental_typecheck.checker_executions += 1;
    record.incremental_typecheck.modules_rechecked += 1;
    record.incremental_typecheck.modules_reused -= 1;
    record.incremental_typecheck.modules_reused_dependency_transport_env -= 1;
    record.work_summary.checked_modules += 1;
    record.ingestion_pipeline.module_header_cache_misses += 1;
    record.ingestion_pipeline.module_header_cache_probes += 1;
  }
  const summary = compareEditCycleRecords(before, after);
  assert.equal(summary.schema, "incremental_phase_summary");
  assert.equal(summary.version, 2);
  assert.deepEqual(summary.modes, editCycleModes);
  assert.deepEqual(summary.work_scopes, editCycleWorkScopes);
  assert.equal(summary.cases.length, editCycleCases.length);
  assert.equal(summary.cases[0].ingestion_pipeline.delta.module_header_cache_misses, 1);
  assert.deepEqual(summary.cases[0].delta, {
    read_bytes: 5,
    hash_calls: 0,
    parsed_files: 0,
    checked_modules: 1,
    codegen_modules: 0,
  });
});

test("phase summary parser rejects malformed and unsafe records", () => {
  assert.throws(() => parseEditCycleJsonl("not-json\n"), /invalid JSON/);
  assert.throws(() => parseEditCycleJsonl("\n"), /at least one record/);
  const unsafe = makeRecord("cold");
  unsafe.work_summary.read_bytes = Number.MAX_SAFE_INTEGER + 1;
  assert.throws(() => parseEditCycleRecord(unsafe), /non-negative safe integer/);
  const inconsistent = makeRecord("cold");
  inconsistent.work_summary.hash_calls += 1;
  assert.throws(() => parseEditCycleRecord(inconsistent), /does not match scoped telemetry/);
  const parseMismatch = makeRecord("cold");
  parseMismatch.ingestion_pipeline.final_semantic_source_parse_executions += 1;
  assert.throws(() => parseEditCycleRecord(parseMismatch), /disagree with schema 2/);
  const codegen = makeRecord("cold");
  codegen.work_summary.codegen_modules = 1;
  assert.throws(() => parseEditCycleRecord(codegen), /codegen_modules to be 0/);
});

test("phase summary rejects incompatible comparison authority before deltas", () => {
  const base = makeSet();
  const checks = [
    ["benchmark", "other", /benchmark/],
    ["fixture_sha256", sha("5"), /fixture_sha256/],
    ["runner_sha256", sha("6"), /runner_sha256/],
    ["endpoint", "build-command-complete", /endpoint/],
    ["schema", "other_kpi", /outer schema\/version/],
    ["version", editCycleRecordVersion + 1, /outer schema\/version/],
  ];
  for (const [key, value, pattern] of checks) {
    const changed = clone(base);
    for (const record of changed) record[key] = value;
    assert.throws(() => compareEditCycleRecords(base, changed), pattern, key);
  }

  const modes = clone(base);
  for (const record of modes) record.modes.typing_dependency_env_reuse = "disabled";
  assert.throws(() => compareEditCycleRecords(base, modes), /typing_dependency_env_reuse/);

  const scopes = clone(base);
  for (const record of scopes) record.work_scopes.read_bytes = "source-only";
  assert.throws(() => compareEditCycleRecords(base, scopes), /read_bytes/);

  const missingCase = clone(base).slice(0, -1);
  assert.throws(() => compareEditCycleRecords(base, missingCase), /case set/);
});

test("phase summary rejects split-case runs and mismatched run topology", () => {
  const split = editCycleCases.map((caseName, index) => makeRecord(caseName, { run: index + 1 }));
  assert.throws(() => compareEditCycleRecords(makeSet(), split), /incomplete case\/run matrix/);

  assert.throws(
    () => compareEditCycleRecords(makeSet({}, [1, 2]), makeSet()),
    /mismatched run topology/,
  );
});

test("phase summary rejects mislabeled case metadata", () => {
  for (const [key, value] of [["edit_kind", "wrong"], ["cache_state", "empty"]]) {
    const records = makeSet();
    records[1][key] = value;
    assert.throws(() => compareEditCycleRecords(makeSet(), records), new RegExp(`exact_noop\\.${key}`));
  }
});

test("phase summary rejects ingestion unit mismatch and disabled stamp activity", () => {
  const unitMismatch = makeRecord("cold");
  unitMismatch.ingestion_fingerprint.hash_input_string_units += 1;
  assert.throws(() => parseEditCycleRecord(unitMismatch), /hash_input_string_units must equal/);

  const stampActivity = makeRecord("cold");
  stampActivity.ingestion_fingerprint.stamp_probes = 1;
  stampActivity.ingestion_fingerprint.stamp_hits = 1;
  assert.throws(() => parseEditCycleRecord(stampActivity), /must be 0 when ingestion stamps are disabled/);
});

test("phase summary rejects the obsolete hashed_files field", () => {
  const record = makeRecord("cold");
  record.work_summary.hashed_files = record.work_summary.hash_calls;
  delete record.work_summary.hash_calls;
  assert.throws(() => parseEditCycleRecord(record), /unexpected fields/);
});

test("phase summary rejects mixed or nondeterministic input records", () => {
  const before = makeSet({}, [1, 2]);
  const after = makeSet({}, [1, 2]);
  const changed = after.find((record) => record.case === "cold" && record.run === 2);
  changed.work_summary.read_bytes += 1;
  changed.host_fs_scope.read_file_returned_bytes += 1;
  assert.throws(() => compareEditCycleRecords(before, after), /nondeterministic cold.read_bytes/);

  const duplicate = makeSet();
  duplicate.push(clone(duplicate[0]));
  assert.throws(() => compareEditCycleRecords(makeSet(), duplicate), /duplicate case\/run/);
});
