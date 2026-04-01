#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const ROOT = process.cwd();
const SCRIPT = path.join(ROOT, "scripts/generate_selfhost_runtime_fixture_tests.mjs");
const OUT_DIR = path.join(ROOT, "_build/bench/selfhost_runtime_fixture_probe");
const GENERATED_DIR = path.join(ROOT, "vibe/compiler/_generated_selfhost_runtime_fixtures");
const SNAPSHOT_FILE =
  process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_SNAPSHOT_FILE ||
  path.join(ROOT, "bench/golden/selfhost_runtime_fixture_snapshot.json");
const VIBE_BIN =
  process.env.VIBE_BIN ||
  path.join(ROOT, "target/native/release/build/cmd/vibe/vibe.exe");
const TIMEOUT_MS = Number(process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_PROBE_TIMEOUT_MS || "30000");
const LIMIT = Number(process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_PROBE_LIMIT || "0");
const REQUIRE_ALL = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_REQUIRE_ALL === "1";

function run(cmd, args, options = {}) {
  return spawnSync(cmd, args, {
    cwd: ROOT,
    encoding: "utf8",
    ...options,
  });
}

function ensureVibeBin() {
  if (fs.existsSync(VIBE_BIN)) return;
  const built = run("moon", ["build", "--target", "native", "--release", "src/cmd/vibe", "--warn-list", "-29"], {
    stdio: "inherit",
  });
  if (built.status !== 0) {
    process.exit(built.status ?? 1);
  }
}

function generatorEnv(extra = {}) {
  return {
    ...process.env,
    ...extra,
  };
}

function listCandidatePaths() {
  const listed = run("node", [SCRIPT], {
    env: generatorEnv({
      VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY: "1",
      ...(LIMIT > 0 ? { VIBE_SELFHOST_RUNTIME_FIXTURE_LIMIT: String(LIMIT) } : {}),
    }),
  });
  if (listed.status !== 0) {
    process.stderr.write(listed.stderr || "");
    process.exit(listed.status ?? 1);
  }
  return listed.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function generateFixtureTest(pathListFile) {
  const generated = run("node", [SCRIPT], {
    env: generatorEnv({
      VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE: pathListFile,
      VIBE_SELFHOST_RUNTIME_FIXTURE_SHARD_SIZE: "1",
    }),
  });
  if (generated.status !== 0) {
    throw new Error(generated.stderr || generated.stdout || "generator failed");
  }
  const paths = generated.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  if (paths.length !== 1) {
    throw new Error(`expected exactly one generated file, got ${paths.length}`);
  }
  return paths[0];
}

function runFixtureTest(testPath) {
  return run(VIBE_BIN, ["test", testPath], {
    env: generatorEnv({
      VIBE_TEST_BACKEND: "compiled",
    }),
    timeout: TIMEOUT_MS,
  });
}

function excerpt(text) {
  const trimmed = (text || "").trim();
  if (!trimmed) return "";
  const lines = trimmed.split("\n");
  return lines.slice(Math.max(0, lines.length - 8)).join("\n");
}

function main() {
  ensureVibeBin();
  fs.mkdirSync(OUT_DIR, { recursive: true });
  try {
    const candidatePaths = listCandidatePaths();
    const passedPaths = [];
    const failedCases = [];

    candidatePaths.forEach((fixturePath, index) => {
      const pathListFile = path.join(OUT_DIR, `case_${String(index + 1).padStart(3, "0")}.txt`);
      fs.writeFileSync(pathListFile, `${fixturePath}\n`);
      const generatedPath = generateFixtureTest(pathListFile);
      process.stdout.write(`[${index + 1}/${candidatePaths.length}] ${fixturePath}\n`);
      const result = runFixtureTest(generatedPath);
      if (result.status === 0) {
        passedPaths.push(fixturePath);
        return;
      }
      failedCases.push({
        path: fixturePath,
        exit_status: result.status,
        signal: result.signal ?? null,
        output_excerpt: excerpt(`${result.stdout || ""}\n${result.stderr || ""}`),
        timeout: result.error?.code === "ETIMEDOUT",
      });
    });

    const snapshot = {
      schema_version: 1,
      timeout_ms: TIMEOUT_MS,
      total_candidates: candidatePaths.length,
      passed_count: passedPaths.length,
      failed_count: failedCases.length,
      candidate_paths: candidatePaths,
      passed_paths: passedPaths,
      failed_cases: failedCases,
    };
    fs.mkdirSync(path.dirname(SNAPSHOT_FILE), { recursive: true });
    fs.writeFileSync(SNAPSHOT_FILE, `${JSON.stringify(snapshot, null, 2)}\n`);
    process.stdout.write(`wrote ${path.relative(ROOT, SNAPSHOT_FILE)}\n`);
    process.stdout.write(`passed=${passedPaths.length} failed=${failedCases.length}\n`);
    if (REQUIRE_ALL && failedCases.length > 0) {
      process.exitCode = 1;
    }
  } finally {
    fs.rmSync(GENERATED_DIR, { recursive: true, force: true });
  }
}

main();
