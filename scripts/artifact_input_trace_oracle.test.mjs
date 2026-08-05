import assert from "node:assert/strict";
import test from "node:test";

import { parseArtifactInputTrace } from "./artifact_input_trace_oracle.mjs";

const validTrace = {
  schema: 2,
  run_nonce: "unit-nonce",
  scope_disclaimer: "observation-only file_compile persistent pre-strip WASI bump lane; trace-only graph/context work; not a production cache key, format, or reuse decision",
  compile_lane: "file_compile.persistent_pre_strip_wasi_cached_bump",
  persistent_artifact_kind: "file-compile-wasi",
  entry: { path: "project/main.vibe", name: "main", mode: "no-dce" },
  source_groups_fingerprint: "20:1:2",
  source_groups_fingerprint_kind: "build_source_groups_fingerprint(source_groups)",
  production_artifact_input_fingerprint: "30:3:4",
  production_artifact_input_fingerprint_kind: "build_file_compile_wasi_artifact_fingerprint_from_group_fingerprint_for_entry_path(source_groups_fingerprint, entry_path, entry_name, mode)",
  compiler_cache_version_tag: "v16|cg-example",
  compiler_cache_version_tag_kind: "persistent_cache_version_tag()",
  effective_config: { checked_error_row_mode: "checked", diagnostics_mode: "fail-fast", dep_order_seed: "0", target: "wasi", memory: "bump", dce_mode: "no-dce", strip_stage: "pre-strip", instrumentation: "uninstrumented" },
  dependency_plan: { fingerprint: "40:5:6", fingerprint_kind: "compact_string_fingerprint(vibe-artifact-input-dependency-plan:v1 length-prefixed planned order/ranks/dependency occurrences)", module_count: 2, edge_occurrence_count: 1 },
  resolution: { env_seed: "|roots=|pins=0", env_seed_kind: "resolution_env_seed()", context_fingerprint: "50:7:8", context_fingerprint_kind: "persistent_resolution_context_fingerprint_fs(entry_path, grouped_source_paths(source_groups))" },
  shadow_artifact_input_fingerprint: "60:9:10",
  shadow_artifact_input_fingerprint_kind: "compact_string_fingerprint(vibe-artifact-input-observation:v2 fixed-order length-prefixed components)",
  persistent_lookup: "miss",
};

test("artifact input trace accepts the exact schema-2 observation", () => {
  assert.deepEqual(parseArtifactInputTrace(JSON.stringify(validTrace), "unit-nonce"), validTrace);
});

test("artifact input trace rejects schema 1, stale, widened, and dishonest observations", () => {
  const schema1 = structuredClone(validTrace);
  schema1.schema = 1;
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(schema1)), /unsupported schema 1/);
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(validTrace), "other-nonce"), /run_nonce mismatch/);
  const widened = structuredClone(validTrace);
  widened.extra = true;
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(widened)), /unexpected or missing fields/);
  const missing = structuredClone(validTrace);
  delete missing.resolution;
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(missing)), /unexpected or missing fields/);
  const dishonestProductionKind = structuredClone(validTrace);
  dishonestProductionKind.production_artifact_input_fingerprint_kind = "some other builder";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(dishonestProductionKind)), /dishonest production artifact fingerprint kind/);
  const dishonestShadowKind = structuredClone(validTrace);
  dishonestShadowKind.shadow_artifact_input_fingerprint_kind = "production key";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(dishonestShadowKind)), /dishonest shadow artifact fingerprint kind/);
});

test("artifact input trace rejects malformed nested evidence and config vocabulary", () => {
  const badConfigKeys = structuredClone(validTrace);
  badConfigKeys.effective_config.cache_dir = "forbidden";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(badConfigKeys)), /effective_config has unexpected or missing fields/);
  const badConfigValue = structuredClone(validTrace);
  badConfigValue.effective_config.dep_order_seed = "000";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(badConfigValue)), /invalid normalized dep-order seed/);
  const badLaneFact = structuredClone(validTrace);
  badLaneFact.effective_config.instrumentation = "coverage";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(badLaneFact)), /dishonest fixed lane config/);
  const badPlan = structuredClone(validTrace);
  badPlan.dependency_plan.edge_occurrence_count = -1;
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(badPlan)), /invalid dependency plan edge occurrence count/);
  const badResolution = structuredClone(validTrace);
  badResolution.resolution.context_fingerprint_kind = "weaker context";
  assert.throws(() => parseArtifactInputTrace(JSON.stringify(badResolution)), /dishonest resolution context fingerprint kind/);
});
