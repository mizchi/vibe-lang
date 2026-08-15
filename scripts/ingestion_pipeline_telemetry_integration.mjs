#!/usr/bin/env node
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(process.argv[2] ?? process.cwd());
const stage2 = resolve(process.argv[3] ?? "");
if (!process.argv[3]) {
  console.error("usage: ingestion_pipeline_telemetry_integration.mjs ROOT STAGE2_WASM");
  process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), "vibe-ingestion-pipeline-"));
const project = join(work, "project");
const cache = join(work, "cache");
mkdirSync(project, { recursive: true });
mkdirSync(cache, { recursive: true });
const entry = join(project, "entry.vibe");
const dep = join(project, "dep.vibe");
writeFileSync(dep, "export fn value(x: Int) -> Int { x + 1 }\n");
writeFileSync(entry, 'import ./dep.vibe { value }\nexport let answer = value(41)\n');

function walkFiles(dir) {
  const out = [];
  for (const item of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, item.name);
    if (item.isDirectory()) out.push(...walkFiles(path));
    else if (item.isFile()) out.push(path);
  }
  return out;
}

function run(label, { checkOnly = true, expectSuccess = true, stale = false, outputPath = null, nonce = `nonce-${label}` } = {}) {
  const output = outputPath ?? join(project, `${label}.out`);
  const pipelinePath = join(project, `${label}.pipeline.json`);
  const incrementalPath = join(project, `${label}.incremental.json`);
  if (stale) writeFileSync(pipelinePath, "stale\n");
  else rmSync(pipelinePath, { force: true });
  rmSync(incrementalPath, { force: true });
  const env = {
    ...process.env,
    VIBE_BUILD_CACHE_DIR: cache,
    VIBE_IMPORT_ABI: "raw",
    VIBE_PREOPEN_DIR: root,
    VIBE_INGESTION_PIPELINE_TELEMETRY_OUT: pipelinePath,
    VIBE_INGESTION_PIPELINE_TELEMETRY_NONCE: nonce,
    VIBE_INCREMENTAL_TELEMETRY_OUT: incrementalPath,
  };
  if (checkOnly) env.VIBE_CHECK_ONLY = "1";
  else delete env.VIBE_CHECK_ONLY;
  const result = spawnSync("bash", [
    join(root, "scripts/run_wasm_vibe_host_runner.sh"),
    "--invoke", "cli_main", stage2, entry, output, "main",
  ], { cwd: root, env, encoding: "utf8" });
  if (expectSuccess && result.status !== 0) {
    throw new Error(`${label} failed: ${result.stdout}\n${result.stderr}`);
  }
  if (!expectSuccess) {
    assert.notEqual(result.status, 0, `${label} unexpectedly succeeded`);
    assert.throws(() => readFileSync(pipelinePath), /ENOENT/, `${label} retained/published a sidecar`);
    return null;
  }
  const pipeline = JSON.parse(readFileSync(pipelinePath, "utf8"));
  const incremental = JSON.parse(readFileSync(incrementalPath, "utf8"));
  assert.equal(pipeline.schema, "ingestion_pipeline");
  assert.equal(pipeline.version, 1);
  assert.equal(pipeline.nonce, nonce);
  assert.equal(
    pipeline.final_semantic_source_parse_executions,
    incremental.current_source_parse_executions,
    `${label}: schema-2 final-parse cross-check`,
  );
  for (const prefix of ["source_list_cache", "source_group_cache", "module_header_cache"]) {
    assert.equal(pipeline[`${prefix}_probes`], pipeline[`${prefix}_hits`] + pipeline[`${prefix}_misses`], `${label}: ${prefix} partition`);
  }
  assert.equal(
    pipeline.source_list_group_reconstruction_attempts,
    pipeline.source_list_group_reconstruction_hits + pipeline.source_list_group_reconstruction_misses,
    `${label}: reconstruction partition`,
  );
  return pipeline;
}

try {
  const cold = run("cold");
  assert.deepEqual(
    [cold.source_group_cache_probes, cold.source_group_cache_hits, cold.source_group_cache_misses],
    [1, 0, 1],
  );
  assert.deepEqual(
    [cold.source_list_group_reconstruction_attempts, cold.source_list_group_reconstruction_hits, cold.source_list_group_reconstruction_misses],
    [1, 0, 1],
  );
  assert.equal(cold.cold_collect_all_sources_executions, 1);
  assert.ok(cold.module_header_cache_probes > 0, "cold check performed no module-header cache probes");
  assert.ok(cold.module_header_cache_misses > 0, "fresh cache performed no cold header misses");
  assert.ok(cold.module_header_parse_scan_executions > 0, "cold check performed no module-header parse scans");
  assert.equal(cold.entry_precheck_parse_executions, 1);
  assert.equal(cold.linked_validation_source_parse_executions, 1);
  assert.equal(cold.warning_entry_parse_executions, 1);

  const warm = run("warm");
  assert.deepEqual(
    [warm.source_group_cache_probes, warm.source_group_cache_hits, warm.source_group_cache_misses],
    [1, 1, 0],
  );
  assert.equal(warm.source_list_cache_probes, 0);
  assert.equal(warm.source_list_group_reconstruction_attempts, 0);
  assert.equal(warm.cold_collect_all_sources_executions, 0);
  assert.deepEqual(
    [warm.module_header_cache_probes, warm.module_header_parse_scan_executions],
    [0, 0],
    "warm TypeEnv reuse should bypass module-header work",
  );

  const groupCache = walkFiles(cache).find((path) => {
    const text = readFileSync(path, "utf8");
    return text.startsWith("version\t4\n") && text.includes("\ngroup\t");
  });
  assert.ok(groupCache, "persistent source-group cache was not found");
  const groupText = readFileSync(groupCache, "utf8");
  assert.match(groupText, /^resctx\t.+$/m);
  writeFileSync(groupCache, groupText.replace(/^resctx\t.+$/m, "resctx\tcorrupt-but-parseable"));

  const corrupt = run("corrupt");
  assert.deepEqual(
    [corrupt.source_group_cache_probes, corrupt.source_group_cache_hits, corrupt.source_group_cache_misses],
    [1, 0, 1],
  );
  assert.deepEqual(
    [corrupt.source_list_group_reconstruction_attempts, corrupt.source_list_group_reconstruction_hits, corrupt.source_list_group_reconstruction_misses],
    [1, 1, 0],
  );
  assert.deepEqual(
    [corrupt.source_list_cache_probes, corrupt.source_list_cache_hits, corrupt.source_list_cache_misses],
    [1, 1, 0],
  );
  assert.equal(corrupt.cold_collect_all_sources_executions, 0);

  // Force both aggregate caches to miss while retaining the per-source header
  // cache created by the cold run. This reaches the real warm-header branch;
  // ordinary warm TypeEnv reuse intentionally bypasses header work entirely.
  const sourceListCache = walkFiles(cache).find((path) => {
    const text = readFileSync(path, "utf8");
    return text.startsWith("version\t4\n") && text.includes("\nsource\t") && !text.includes("\ngroup\t");
  });
  assert.ok(sourceListCache, "persistent source-list cache was not found");
  const freshGroupText = readFileSync(groupCache, "utf8");
  writeFileSync(groupCache, freshGroupText.replace(/^resctx\t.+$/m, "resctx\tforce-header-cache-hit"));
  const sourceListText = readFileSync(sourceListCache, "utf8");
  writeFileSync(sourceListCache, sourceListText.replace(/^resctx\t.+$/m, "resctx\tforce-header-cache-hit"));

  const headerWarm = run("header-cache-hit");
  assert.deepEqual(
    [headerWarm.source_group_cache_probes, headerWarm.source_group_cache_hits, headerWarm.source_group_cache_misses],
    [1, 0, 1],
  );
  assert.ok(headerWarm.source_list_cache_probes > 0);
  assert.equal(headerWarm.source_list_cache_hits, 0);
  assert.equal(headerWarm.source_list_cache_misses, headerWarm.source_list_cache_probes);
  assert.equal(headerWarm.cold_collect_all_sources_executions, 1);
  assert.ok(headerWarm.module_header_cache_probes > 0, "header-warm check performed no module-header probes");
  assert.equal(
    headerWarm.module_header_cache_hits,
    headerWarm.module_header_cache_probes,
    "header-warm check did not hit every retained module header",
  );
  assert.equal(headerWarm.module_header_cache_misses, 0);
  assert.equal(headerWarm.module_header_parse_scan_executions, 0);

  const failedOutput = join(project, "failed-output-directory");
  mkdirSync(failedOutput);
  run("failed-output", { expectSuccess: false, stale: true, outputPath: failedOutput });

  // UTF-8 continuation bytes are not C1 controls. Compiler and Node decoding
  // must agree that a control-free Unicode request nonce is valid.
  run("unicode-nonce", { nonce: "あ" });

  // Clear all requested sidecars before validating either request. An invalid
  // fingerprint nonce must not leave a stale pipeline observation behind.
  const siblingPipelinePath = join(project, "invalid-sibling.pipeline.json");
  const siblingFingerprintPath = join(project, "invalid-sibling.fingerprint.json");
  writeFileSync(siblingPipelinePath, "stale\n");
  writeFileSync(siblingFingerprintPath, "stale\n");
  const invalidSibling = spawnSync("bash", [
    join(root, "scripts/run_wasm_vibe_host_runner.sh"),
    "--invoke", "cli_main", stage2, entry, join(project, "invalid-sibling.out"), "main",
  ], {
    cwd: root,
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_IMPORT_ABI: "raw",
      VIBE_PREOPEN_DIR: root,
      VIBE_CHECK_ONLY: "1",
      VIBE_INGESTION_TELEMETRY_OUT: siblingFingerprintPath,
      VIBE_INGESTION_TELEMETRY_NONCE: "invalid\nnonce",
      VIBE_INGESTION_PIPELINE_TELEMETRY_OUT: siblingPipelinePath,
      VIBE_INGESTION_PIPELINE_TELEMETRY_NONCE: "valid-pipeline-nonce",
    },
    encoding: "utf8",
  });
  assert.notEqual(invalidSibling.status, 0, "invalid sibling nonce unexpectedly succeeded");
  assert.throws(() => readFileSync(siblingFingerprintPath), /ENOENT/, "stale fingerprint sidecar survived validation");
  assert.throws(() => readFileSync(siblingPipelinePath), /ENOENT/, "stale pipeline sidecar survived sibling validation");

  writeFileSync(entry, "export let broken =\n");
  run("failed-check", { expectSuccess: false, stale: true });
  writeFileSync(entry, 'import ./dep.vibe { value }\nexport let answer = value(41)\n');
  run("unsupported-mode", { checkOnly: false, expectSuccess: false, stale: true });

  console.log("ingestion-pipeline telemetry integration: ok");
} finally {
  rmSync(work, { recursive: true, force: true });
}
