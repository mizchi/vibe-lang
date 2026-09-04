import assert from "node:assert/strict";
import test from "node:test";

import {
  assertDisabledIngestionStamps,
  buildEditCycleWorkSummary,
  editCycleModes,
  parseEditCycleRunCount,
  pinEditCycleModes,
  parseHostFsScopeTelemetry,
  parseIncrementalTelemetry,
  parseIngestionFingerprintTelemetry,
  parseIngestionPipelineTelemetry,
} from "./edit_cycle_kpi.mjs";

const validSidecar = JSON.stringify({
  schema: 2,
  modules_planned: 2,
  modules_rechecked: 1,
  modules_reused: 1,
  parse_operations: 3,
  modules_failed_or_blocked: 0,
  current_source_parse_executions: 1,
  checker_executions: 1,
  modules_reused_conservative_fingerprint: 0,
  modules_reused_dependency_transport_env: 1,
});

const validIngestionFingerprint = {
  schema: "ingestion_fingerprint",
  version: 1,
  nonce: "run-123",
  source_read_calls: 2,
  source_read_string_units: 7,
  hash_calls: 2,
  hash_input_string_units: 7,
  stamp_probes: 3,
  stamp_hits: 1,
  stamp_misses: 1,
  stamp_malformed: 1,
  stamp_text_units_read: 11,
  stamp_publications: 2,
};

export const validIngestionPipeline = {
  schema: "ingestion_pipeline",
  version: 1,
  nonce: "run-123",
  source_list_cache_probes: 2,
  source_list_cache_hits: 1,
  source_list_cache_misses: 1,
  source_group_cache_probes: 1,
  source_group_cache_hits: 0,
  source_group_cache_misses: 1,
  source_list_group_reconstruction_attempts: 1,
  source_list_group_reconstruction_hits: 0,
  source_list_group_reconstruction_misses: 1,
  cold_collect_all_sources_executions: 1,
  module_header_cache_probes: 3,
  module_header_cache_hits: 1,
  module_header_cache_misses: 2,
  module_header_parse_scan_executions: 2,
  entry_precheck_parse_executions: 1,
  final_semantic_source_parse_executions: 1,
  linked_validation_source_parse_executions: 1,
  warning_entry_parse_executions: 1,
};

const validHostFsScope = {
  schema: "host_fs_scope",
  version: 1,
  nonce: "run-123",
  read_file_calls: 2,
  read_file_returned_bytes: 7,
  read_bytes_calls: 3,
  read_bytes_returned_bytes: 11,
  stat_token_calls: 5,
  exists_calls: 13,
};

test("edit-cycle KPI accepts a complete incremental typecheck sidecar", () => {
  assert.deepEqual(parseIncrementalTelemetry(validSidecar), JSON.parse(validSidecar));
});

test("edit-cycle KPI rejects malformed or internally inconsistent telemetry", () => {
  assert.throws(
    () => parseIncrementalTelemetry("not json"),
    /invalid JSON/,
  );
  assert.throws(
    () => parseIncrementalTelemetry(JSON.stringify({
      ...JSON.parse(validSidecar),
      modules_rechecked: 2,
    })),
    /must equal modules_planned/,
  );
  assert.throws(
    () => parseIncrementalTelemetry(JSON.stringify({
      ...JSON.parse(validSidecar),
      modules_reused_conservative_fingerprint: 1,
      modules_reused_dependency_transport_env: 1,
    })),
    /reuse-class counters must sum/,
  );
  const missing = JSON.parse(validSidecar);
  delete missing.checker_executions;
  assert.throws(
    () => parseIncrementalTelemetry(JSON.stringify(missing)),
    /exactly the incremental telemetry v2 fields/,
  );
  assert.throws(
    () => parseIncrementalTelemetry(JSON.stringify({ ...JSON.parse(validSidecar), extra: 1 })),
    /exactly the incremental telemetry v2 fields/,
  );
});

test("edit-cycle KPI accepts a complete ingestion fingerprint sidecar", () => {
  assert.deepEqual(
    parseIngestionFingerprintTelemetry(JSON.stringify(validIngestionFingerprint), "run-123"),
    validIngestionFingerprint,
  );
});

test("edit-cycle KPI fails closed on invalid ingestion fingerprint sidecars", () => {
  assert.throws(
    () => parseIngestionFingerprintTelemetry(JSON.stringify({ ...validIngestionFingerprint, nonce: "other" }), "run-123"),
    /nonce mismatch/,
  );
  assert.throws(
    () => parseIngestionFingerprintTelemetry(JSON.stringify({ ...validIngestionFingerprint, stamp_probes: 2 }), "run-123"),
    /stamp_probes must equal/,
  );
  assert.throws(
    () => parseIngestionFingerprintTelemetry(JSON.stringify({ ...validIngestionFingerprint, extra: 1 }), "run-123"),
    /exactly the ingestion_fingerprint v1 fields/,
  );
});

test("edit-cycle KPI accepts strict ingestion_pipeline v1 telemetry", () => {
  assert.deepEqual(
    parseIngestionPipelineTelemetry(JSON.stringify(validIngestionPipeline), "run-123"),
    validIngestionPipeline,
  );
});

test("edit-cycle KPI rejects hostile ingestion_pipeline sidecars", () => {
  for (const [patch, message] of [
    [{ nonce: "other" }, /nonce mismatch/],
    [{ nonce: "bad\u0000nonce" }, /control characters/],
    [{ version: 2 }, /unsupported ingestion_pipeline/],
    [{ source_list_cache_probes: 3 }, /source_list_cache_probes must equal/],
    [{ source_list_group_reconstruction_attempts: 2 }, /reconstruction attempts must equal/],
    [{ module_header_cache_hits: -1 }, /non-negative safe integer/],
    [{ module_header_cache_hits: 1.5 }, /non-negative safe integer/],
    [{ module_header_cache_hits: Number.MAX_SAFE_INTEGER + 1 }, /non-negative safe integer/],
    [{ extra: 1 }, /exactly the ingestion_pipeline v1 fields/],
  ]) {
    const expectedNonce = patch.nonce?.includes("\u0000") ? patch.nonce : "run-123";
    assert.throws(
      () => parseIngestionPipelineTelemetry(JSON.stringify({ ...validIngestionPipeline, ...patch }), expectedNonce),
      message,
    );
  }
  const missing = { ...validIngestionPipeline };
  delete missing.warning_entry_parse_executions;
  assert.throws(() => parseIngestionPipelineTelemetry(JSON.stringify(missing), "run-123"), /exactly/);
  assert.throws(() => parseIngestionPipelineTelemetry('{"schema":', "run-123"), /invalid JSON/);
});

test("edit-cycle KPI accepts a complete host_fs_scope sidecar", () => {
  assert.deepEqual(
    parseHostFsScopeTelemetry(JSON.stringify(validHostFsScope), "run-123"),
    validHostFsScope,
  );
});

test("edit-cycle KPI pins authority modes after ambient environment", () => {
  const env = pinEditCycleModes({
    KEEP: "yes",
    VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP: "1",
    VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: "1",
    VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: "/tmp/ambient",
    VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "ambient",
  });
  assert.equal(env.KEEP, "yes");
  for (const key of [
    "VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP",
    "VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE",
    "VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT",
    "VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE",
  ]) assert.equal(env[key], "");
  assert.deepEqual(editCycleModes, {
    persistent_ingestion_stamp: "disabled",
    typing_dependency_env_reuse: "default-on",
    invalidation_trace: "disabled",
    compilation: "check-only",
  });
});

test("edit-cycle KPI parses only whole positive safe-integer run counts", () => {
  assert.equal(parseEditCycleRunCount(undefined), 3);
  assert.equal(parseEditCycleRunCount(""), 3);
  assert.equal(parseEditCycleRunCount("12"), 12);
  for (const invalid of ["1x", "1.5", "0x10", "0", "-1", "01", "9007199254740992"]) {
    assert.throws(() => parseEditCycleRunCount(invalid), /positive decimal safe integer/, invalid);
  }
});

test("edit-cycle KPI enforces ingestion unit and disabled-stamp invariants", () => {
  assert.throws(
    () => parseIngestionFingerprintTelemetry(
      JSON.stringify({ ...validIngestionFingerprint, hash_input_string_units: 8 }),
      "run-123",
    ),
    /hash_input_string_units must equal source_read_string_units/,
  );
  assert.doesNotThrow(() => assertDisabledIngestionStamps({
    ...validIngestionFingerprint,
    stamp_probes: 0,
    stamp_hits: 0,
    stamp_misses: 0,
    stamp_malformed: 0,
    stamp_text_units_read: 0,
    stamp_publications: 0,
  }));
  assert.throws(
    () => assertDisabledIngestionStamps(validIngestionFingerprint),
    /must be 0 when ingestion stamps are disabled/,
  );
});

test("edit-cycle KPI derives the scoped check-only work summary", () => {
  assert.deepEqual(
    buildEditCycleWorkSummary(
      JSON.parse(validSidecar),
      validIngestionFingerprint,
      validHostFsScope,
    ),
    {
      read_bytes: 18,
      hash_calls: 2,
      parsed_files: 1,
      checked_modules: 1,
      codegen_modules: 0,
    },
  );
  assert.throws(
    () => buildEditCycleWorkSummary(
      JSON.parse(validSidecar),
      validIngestionFingerprint,
      { ...validHostFsScope, read_file_returned_bytes: Number.MAX_SAFE_INTEGER },
    ),
    /safe integer range/,
  );
});

test("edit-cycle KPI fails closed on invalid host_fs_scope sidecars", () => {
  assert.throws(
    () => parseHostFsScopeTelemetry("not json", "run-123"),
    /invalid JSON/,
  );
  assert.throws(
    () => parseHostFsScopeTelemetry(JSON.stringify({ ...validHostFsScope, nonce: "other" }), "run-123"),
    /nonce mismatch/,
  );
  assert.throws(
    () => parseHostFsScopeTelemetry(JSON.stringify({ ...validHostFsScope, nonce: "bad\u0000nonce" }), "bad\u0000nonce"),
    /control characters/,
  );
  assert.throws(
    () => parseHostFsScopeTelemetry(JSON.stringify({ ...validHostFsScope, exists_calls: -1 }), "run-123"),
    /non-negative safe integer/,
  );
  assert.throws(
    () => parseHostFsScopeTelemetry(JSON.stringify({ ...validHostFsScope, extra: 1 }), "run-123"),
    /exactly the host_fs_scope v1 fields/,
  );
});
