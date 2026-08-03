import assert from "node:assert/strict";
import test from "node:test";

import {
  parseHostFsScopeTelemetry,
  parseIncrementalTelemetry,
  parseIngestionFingerprintTelemetry,
} from "./edit_cycle_kpi.mjs";

const validSidecar = JSON.stringify({
  schema: 1,
  modules_planned: 2,
  modules_rechecked: 1,
  modules_reused: 1,
  parse_operations: 3,
  modules_failed_or_blocked: 0,
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
      schema: 1,
      modules_planned: 2,
      modules_rechecked: 2,
      modules_reused: 1,
      parse_operations: 3,
      modules_failed_or_blocked: 0,
    })),
    /must equal modules_planned/,
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

test("edit-cycle KPI accepts a complete host_fs_scope sidecar", () => {
  assert.deepEqual(
    parseHostFsScopeTelemetry(JSON.stringify(validHostFsScope), "run-123"),
    validHostFsScope,
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
