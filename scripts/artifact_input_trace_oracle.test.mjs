import assert from "node:assert/strict";
import test from "node:test";

import { parseArtifactInputTrace } from "./artifact_input_trace_oracle.mjs";

const validTrace = {
  schema: 1,
  run_nonce: "unit-nonce",
  scope_disclaimer: "observation-only file_compile persistent pre-strip WASI bump lane; not a production cache key, format, or reuse decision",
  compile_lane: "file_compile.persistent_pre_strip_wasi_cached_bump",
  persistent_artifact_kind: "file-compile-wasi",
  entry: { path: "project/main.vibe", name: "main", mode: "no-dce" },
  source_groups_fingerprint: "20:1:2",
  source_groups_fingerprint_kind: "build_source_groups_fingerprint(source_groups)",
  artifact_input_fingerprint: "30:3:4",
  artifact_input_fingerprint_kind: "build_file_compile_wasi_artifact_fingerprint_from_group_fingerprint_for_entry_path(source_groups_fingerprint, entry_path, entry_name, mode)",
  persistent_lookup: "miss",
};

test("artifact input trace accepts the exact versioned observation schema", () => {
  assert.deepEqual(parseArtifactInputTrace(JSON.stringify(validTrace), "unit-nonce"), validTrace);
});

test("artifact input trace rejects stale, widened, and dishonest observations", () => {
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(validTrace), "other-nonce"), /run_nonce mismatch/);
  const widened = structuredClone(validTrace);
  widened.extra = true;
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(widened)), /unexpected or missing fields/);
  const dishonestSourceKind = structuredClone(validTrace);
  dishonestSourceKind.source_groups_fingerprint_kind = "compact_string_fingerprint";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(dishonestSourceKind)), /dishonest source groups fingerprint kind/);
  const dishonestArtifactKind = structuredClone(validTrace);
  dishonestArtifactKind.artifact_input_fingerprint_kind = "some other builder";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(dishonestArtifactKind)), /dishonest artifact input fingerprint kind/);
  const wrongLane = structuredClone(validTrace);
  wrongLane.compile_lane = "fs_compile";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(wrongLane)), /wrong compile lane/);
  const invalidLookup = structuredClone(validTrace);
  invalidLookup.persistent_lookup = "unknown";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(invalidLookup)), /invalid persistent lookup/);
});
