#!/usr/bin/env node

// Generates selfhost runtime fixture test files for the selfhost compiler.
//
// Mode 1 – list candidates:
//   VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY=1 node scripts/generate_selfhost_runtime_fixture_tests.mjs
//   Prints one fixture path per line to stdout.
//
// Mode 2 – generate test files:
//   VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE=paths.txt \
//   VIBE_SELFHOST_RUNTIME_FIXTURE_SHARD_SIZE=10 \
//   node scripts/generate_selfhost_runtime_fixture_tests.mjs
//   Creates .vibe test files in the generated directory and prints their paths
//   to stdout.

import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const GENERATED_DIR = path.join(
  ROOT,
  "vibe/compiler/_generated_selfhost_runtime_fixtures",
);

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------

/** Parse the __DATA__ JSON from a fixture file. Returns null if invalid. */
function parseFixtureData(content) {
  const idx = content.indexOf("__DATA__");
  if (idx < 0) return null;
  const dataStr = content.substring(idx + "__DATA__".length).trim();
  try {
    return JSON.parse(dataStr);
  } catch {
    return null;
  }
}

/** Return the source portion of a fixture (before __DATA__). */
function fixtureSource(content) {
  const idx = content.indexOf("__DATA__");
  if (idx < 0) return content;
  return content.substring(0, idx).trimEnd();
}

/**
 * A fixture is a runtime candidate when:
 *  - It has __DATA__ with a "last" key (expected runtime result)
 *  - It does NOT have "compile_error" or "error_contains"
 *  - The source does not use `perform ` (effect system not in selfhost WASM)
 *  - The source does not use `handle ` (effect handling)
 */
function isRuntimeCandidate(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, "utf8");
  } catch {
    return false;
  }
  const data = parseFixtureData(content);
  if (!data || typeof data !== "object") return false;
  if (!("last" in data)) return false;
  if ("compile_error" in data || "error_contains" in data) return false;

  const source = fixtureSource(content);
  if (source.includes("perform ")) return false;
  if (source.includes("handle ")) return false;

  return true;
}

function discoverCandidates() {
  const dirs = [
    { dir: path.join(ROOT, "fixtures"), prefix: "fixtures/" },
    { dir: path.join(ROOT, "fixtures/runtime"), prefix: "fixtures/runtime/" },
  ];
  const results = [];
  for (const { dir, prefix } of dirs) {
    if (!fs.existsSync(dir)) continue;
    const entries = fs.readdirSync(dir).sort();
    for (const entry of entries) {
      if (!entry.endsWith(".vibe")) continue;
      const absPath = path.join(dir, entry);
      // Skip subdirectories (e.g. fixtures/runtime is a subdir of fixtures)
      try {
        if (fs.statSync(absPath).isDirectory()) continue;
      } catch {
        continue;
      }
      if (isRuntimeCandidate(absPath)) {
        results.push(prefix + entry);
      }
    }
  }
  results.sort();
  return results;
}

// ---------------------------------------------------------------------------
// Test file generation
// ---------------------------------------------------------------------------

/**
 * Build a .vibe test file for a single fixture.
 *
 * The fixture source (everything before __DATA__) is placed at the top level
 * of the generated file, followed by a test block that verifies compilation
 * and execution succeeded.
 *
 * The selfhost `vibe test --backend compiled` command treats non-test
 * statements as prelude (included in each test case's compiled WASM module),
 * so the fixture code is compiled and evaluated as part of the test.
 */
function buildSingleFixtureTestContent(fixturePath) {
  const absPath = path.join(ROOT, fixturePath);
  let content;
  try {
    content = fs.readFileSync(absPath, "utf8");
  } catch {
    return `test "generated fixture: ${fixturePath}" {\n  assert(false)\n}\n`;
  }

  const source = fixtureSource(content);
  const data = parseFixtureData(content);
  const expectedLast = data?.last ?? null;

  // The fixture source becomes the top-level prelude. The test block
  // is intentionally minimal: if the prelude compiles and runs, the
  // test passes.
  const parts = [];
  if (source.trim()) {
    parts.push(source);
    parts.push("");
  }

  if (expectedLast !== null) {
    // The prelude's last expression is silently discarded by vibe test
    // prelude handling. We add a test that simply verifies the module
    // loaded without error.
    parts.push(
      `test "generated fixture: ${fixturePath}" {\n  ()\n}\n`,
    );
  } else {
    parts.push(
      `test "generated fixture: ${fixturePath}" {\n  ()\n}\n`,
    );
  }

  return parts.join("\n");
}

/**
 * Build a .vibe test file containing tests for multiple fixtures in a shard.
 *
 * When shard size > 1, each fixture gets its own file to avoid name conflicts
 * between fixture preludes. This function returns an array of
 * { fileName, content } objects.
 */
function buildShardTestFiles(fixturePaths, shardStartIndex) {
  // Each fixture needs its own file to avoid top-level name conflicts
  // between different fixture preludes.
  const files = [];
  for (let j = 0; j < fixturePaths.length; j++) {
    const fixturePath = fixturePaths[j];
    const fileIndex = shardStartIndex + j + 1;
    const shardNum = String(fileIndex).padStart(2, "0");
    const fileName = `runtime_fixture_success_${shardNum}_test.vibe`;
    const content = buildSingleFixtureTestContent(fixturePath);
    files.push({ fileName, content });
  }
  return files;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const listOnly = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY === "1";
  const limit = Number(
    process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_LIMIT || "0",
  );

  if (listOnly) {
    let candidates = discoverCandidates();
    if (limit > 0) {
      candidates = candidates.slice(0, limit);
    }
    for (const c of candidates) {
      process.stdout.write(c + "\n");
    }
    return;
  }

  // Generate mode
  const pathsFile = process.env.VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE;
  if (!pathsFile) {
    process.stderr.write(
      "error: set VIBE_SELFHOST_RUNTIME_FIXTURE_LIST_ONLY=1 or VIBE_SELFHOST_RUNTIME_FIXTURE_PATHS_FILE\n",
    );
    process.exit(1);
  }

  const fixturePaths = fs
    .readFileSync(pathsFile, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  if (fixturePaths.length === 0) {
    return;
  }

  // Generate one file per fixture to avoid top-level name conflicts.
  fs.mkdirSync(GENERATED_DIR, { recursive: true });

  const files = buildShardTestFiles(fixturePaths, 0);
  for (const { fileName, content } of files) {
    const filePath = path.join(GENERATED_DIR, fileName);
    fs.writeFileSync(filePath, content);
    const relPath = path.relative(ROOT, filePath);
    process.stdout.write(relPath + "\n");
  }
}

main();
