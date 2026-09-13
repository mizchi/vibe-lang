#!/usr/bin/env node
// #2767: does the per-file AST cache reach the lane that actually parses?
//
// The cache (VIBE_EXPERIMENTAL_AST_CACHE=1) stores one binary AST per source
// on a cold build. Whether a WARM build reads them is a property of where the
// prefetch is hung, and it used to be hung in one place only -- the header
// pass -- which a warm build never reaches, because planning answers from the
// persistent dep list first. So the ASTs were written on every cold build and
// read on none, and nothing said so: a warm build's heap was byte-identical
// with the cache on and off.
//
// The signature this pins, on a real build (not a check -- the merge/flatten
// lane is what re-parses), stated RELATIVE TO THE COLD BUILD rather than
// against zero. A cold build's merge lane parses nothing, because planning
// already filled the shared memo; whatever residue a particular closure has
// (a source the merge sees and planning did not) is present on every run, so
// the cold count is the floor and an absolute 0 would be a claim about the
// fixture instead of about the cache.
//
//   warm, cache off  non_walk_parse_operations > cold   ast_cache_prefetches 0
//   warm, cache on   non_walk_parse_operations = cold   ast_cache_prefetches > 0
//
// The first row is the control and the second is the claim; before the fix the
// second row read like the first. The two warm runs share one cache directory
// warmed the same way, so the flag is the only difference between them -- and
// they must produce a byte-identical program, because a cache that changes the
// output is not a cache.
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`ast-cache-prefetch-oracle: ${message}`); };

function makeProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "leaf.vibe"), "export fn leaf() -> Int { 1 }\n");
  writeFileSync(join(project, "middle.vibe"), "import ./leaf.vibe { leaf }\nexport fn middle() -> Int { leaf() + 1 }\n");
  writeFileSync(join(project, "app.vibe"), "import ./middle.vibe { middle }\nfn main() -> Int { middle() }\n");
}

function telemetry(path) {
  const value = JSON.parse(readFileSync(path, "utf8"));
  // 4 and 5 are the same counter set apart from the checked-module reuse
  // class; both carry the two lane-parse counters this oracle reads.
  if (value.schema !== 4 && value.schema !== 5) fail(`unexpected telemetry schema ${JSON.stringify(value.schema)}`);
  for (const key of ["modules_planned", "parse_operations", "non_walk_parse_operations", "ast_cache_prefetches"]) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`invalid ${key} in ${path}`);
  }
  return value;
}

function build(stage2, project, cache, astCache, name) {
  const out = `${name}.wasm`;
  const telemetryOut = `${name}.telemetry.json`;
  const result = spawnSync("bash", [join(root, "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main", stage2, "app.vibe", out, "main"], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      VIBE_EXPERIMENTAL_AST_CACHE: astCache ? "1" : "",
      VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryOut,
    },
  });
  if (result.status !== 0) fail(`${name} failed: ${(result.stderr || result.stdout).trim()}`);
  return { bytes: readFileSync(join(project, out)), telemetry: telemetry(join(project, telemetryOut)) };
}

function main() {
  if (!process.argv[2]) fail("usage: ast_cache_prefetch_oracle.mjs <stage2.wasm>");
  // Each build runs with cwd inside the throwaway project, so a relative
  // artifact path would resolve there and the runner would report a missing
  // module rather than anything about the cache.
  const stage2 = resolve(process.argv[2]);
  const work = mkdtempSync(join(tmpdir(), "vibe-ast-cache-oracle-"));
  try {
    const project = join(work, "project");
    const cache = join(work, "cache");
    makeProject(project);
    mkdirSync(cache, { recursive: true });

    const cold = build(stage2, project, cache, true, "cold-on");
    const coldParses = cold.telemetry.non_walk_parse_operations;
    const warmOn = build(stage2, project, cache, true, "warm-on");
    const warmOff = build(stage2, project, cache, false, "warm-off");

    // The control FIRST: with the cache off, a warm build's merge lane parses
    // strictly more than a cold one did, because nothing filled the memo. If
    // that stops being true the claim below is vacuous -- it would be
    // comparing two runs that both parse nothing -- so this is an assertion
    // about the oracle, not about the compiler.
    if (warmOff.telemetry.non_walk_parse_operations <= coldParses) {
      fail(`warm build with the cache OFF parsed ${warmOff.telemetry.non_walk_parse_operations} in the merge lane, not more than the cold build's ${coldParses}: the comparison below would be vacuous`);
    }
    if (warmOff.telemetry.ast_cache_prefetches !== 0) {
      fail(`warm build with the cache OFF prefetched ${warmOff.telemetry.ast_cache_prefetches} ASTs`);
    }

    if (warmOn.telemetry.ast_cache_prefetches < 1) {
      fail("warm build with the cache ON prefetched no stored AST: the cache is written on every cold build and read on none (#2767)");
    }
    if (warmOn.telemetry.non_walk_parse_operations !== coldParses) {
      fail(`warm build with the cache ON parsed ${warmOn.telemetry.non_walk_parse_operations} sources in the merge lane, against the cold build's ${coldParses}`);
    }

    if (!warmOn.bytes.equals(warmOff.bytes) || !warmOn.bytes.equals(cold.bytes)) {
      fail("the AST cache changed the emitted program");
    }

    console.log(`ast-cache-prefetch-oracle: ok (warm prefetches=${warmOn.telemetry.ast_cache_prefetches}; merge-lane parses cold=${coldParses} warm-off=${warmOff.telemetry.non_walk_parse_operations} warm-on=${warmOn.telemetry.non_walk_parse_operations})`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

main();
