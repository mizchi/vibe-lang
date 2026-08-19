#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generator = path.join(repoRoot, "scripts/generate_runtime_fixture_tests.mjs");
const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-runtime-fixture-test-"));

function write(relativePath, content) {
  const target = path.join(workspace, relativePath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content);
}

function run(extraEnv, expectedStatus = 0) {
  const result = spawnSync(process.execPath, [generator], {
    cwd: workspace,
    env: { ...process.env, ...extraEnv },
    encoding: "utf8",
  });
  assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
  return result;
}

function list(mode) {
  return run({
    VIBE_RUNTIME_FIXTURE_LIST_ONLY: "1",
    VIBE_RUNTIME_FIXTURE_INVENTORY: mode,
    // Inventory mode must be exhaustive and immune to ambient developer knobs.
    VIBE_RUNTIME_FIXTURE_INCLUDE_DEBT: mode === "active" ? "1" : "0",
    VIBE_RUNTIME_FIXTURE_LIMIT: "1",
  }).stdout.trim().split("\n").filter(Boolean);
}

try {
  const longName =
    "same_name_with_a_very_long_suffix_that_must_be_truncated_without_losing_identity_aaaaaaaa.vibe";
  write(
    "fixtures/nested/final_binding.vibe",
    '1\nlet x = 2\n\n__DATA__\n{"last":"2"}\n',
  );
  write(`fixtures/a/${longName}`, '3\n\n__DATA__\n{"last":"3"}\n');
  write(`fixtures/b/${longName}`, '4\n\n__DATA__\n{"last":"4"}\n');
  write(
    "fixtures/err_import_collides_with_local_let.vibe",
    'let abs = (x: Int) -> Int { x }\nimport @vibe/builtin { abs }\nabs(-1)\n\n__DATA__\n{"last":"-1"}\n',
  );
  write(
    "scripts/runtime_fixture_debt.tsv",
    "fixtures/err_import_collides_with_local_let.vibe\tgenerator debt: preserving top-level collision scope requires a dedicated lane\n",
  );

  const active = list("active");
  const all = list("all");
  assert.equal(active.length, 3);
  assert.equal(all.length, 4);
  assert(active.includes("fixtures/nested/final_binding.vibe"));
  assert(!active.includes("fixtures/err_import_collides_with_local_let.vibe"));
  assert(all.includes("fixtures/err_import_collides_with_local_let.vibe"));

  const pathsOne = path.join(workspace, "paths-one.txt");
  const pathsMany = path.join(workspace, "paths-many.txt");
  write("paths-one.txt", "fixtures/nested/final_binding.vibe\n");
  write(
    "paths-many.txt",
    `fixtures/a/${longName}\nfixtures/nested/final_binding.vibe\nfixtures/b/${longName}\n`,
  );
  const outOne = path.join(workspace, "out-one");
  const outMany = path.join(workspace, "out-many");
  run({
    VIBE_RUNTIME_FIXTURE_PATHS_FILE: pathsOne,
    VIBE_RUNTIME_FIXTURE_OUTPUT_DIR: outOne,
  });
  run({
    VIBE_RUNTIME_FIXTURE_PATHS_FILE: pathsMany,
    VIBE_RUNTIME_FIXTURE_OUTPUT_DIR: outMany,
  });
  const oneName = fs.readdirSync(outOne)[0];
  assert(fs.existsSync(path.join(outMany, oneName)));
  const generated = fs.readdirSync(outMany);
  assert.equal(new Set(generated).size, 3);
  assert(Math.max(...generated.map((name) => name.length)) <= 96);
  const bindingTest = fs.readFileSync(path.join(outOne, oneName), "utf8");
  assert.match(bindingTest, /let _ = \(\s*1\s*\)/);
  assert.match(bindingTest, /assert_true\(__to_string\(x\) == "2"\)/);

  write("fixtures/nested/malformed.vibe", "5\n\n__DATA__\nnot json\n");
  const malformed = run(
    {
      VIBE_RUNTIME_FIXTURE_LIST_ONLY: "1",
      VIBE_RUNTIME_FIXTURE_INVENTORY: "active",
    },
    1,
  );
  assert.match(malformed.stderr, /malformed\.vibe: __DATA__ marker must be followed by valid JSON/);
  fs.rmSync(path.join(workspace, "fixtures/nested/malformed.vibe"));

  write("fixtures/nested/non_string.vibe", '6\n\n__DATA__\n{"last":null}\n');
  const nonString = run(
    {
      VIBE_RUNTIME_FIXTURE_LIST_ONLY: "1",
      VIBE_RUNTIME_FIXTURE_INVENTORY: "active",
    },
    1,
  );
  assert.match(nonString.stderr, /non_string\.vibe: __DATA__\.last must be a string/);

  process.stdout.write("runtime fixture generator self-test: ok\n");
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}
