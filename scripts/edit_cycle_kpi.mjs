#!/usr/bin/env node
// Minimal user-visible incremental-build baseline.
//
//   node scripts/edit_cycle_kpi.mjs <stage2.wasm> [out.jsonl]
//
// The benchmark copies bench/incremental/edit_cycle into a temporary project,
// uses one isolated persistent cache per repetition, and never edits tracked
// sources or generated compiler bundles. It measures the current one-shot
// `vibe check` behavior and records its opt-in db_typecheck_fs work counters.

import { createHash } from "node:crypto";
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
];

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
  if (telemetry.schema !== 1) {
    throw new Error(`${source}: unsupported schema ${JSON.stringify(telemetry.schema)}`);
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

  const runs = Number.parseInt(process.env.VIBE_EDIT_CYCLE_RUNS || "3", 10);
  if (!Number.isInteger(runs) || runs < 1) {
    console.error(`edit-cycle-kpi: VIBE_EDIT_CYCLE_RUNS must be positive, got ${process.env.VIBE_EDIT_CYCLE_RUNS}`);
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
    rmSync(telemetryPath, { force: true });
    const start = process.hrtime.bigint();
    const result = spawnSync(launcher, ["check", "entry.vibe"], {
      cwd: project,
      encoding: "utf8",
      env: {
        ...process.env,
        VIBE_BUILD_CACHE_DIR: cache,
        VIBE_CLI_CWASM: "",
        VIBE_CLI_WASM: stage2,
        VIBE_HOME: join(work, "home"),
        VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryPath,
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
    records.push({
      schema: 2,
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
      incremental_typecheck: telemetry,
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
