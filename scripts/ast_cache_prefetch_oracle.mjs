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
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

// Two independent leaves, so editing one leaves the other REUSED -- which is
// the state in which a stored AST has to serve the merge.
function makeSplitProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "a.vibe"), "export fn a() -> Int { 1 }\n");
  writeFileSync(join(project, "b.vibe"), "export fn b() -> Int { 2 }\n");
  writeFileSync(join(project, "app.vibe"), "import ./a.vibe { a }\nimport ./b.vibe { b }\nfn main() -> Int { a() + b() }\n");
}

function editA(project, marker) {
  writeFileSync(join(project, "a.vibe"), `export fn a() -> Int { let unused${marker} = 0\n1 }\n`);
}

function telemetry(path) {
  const value = JSON.parse(readFileSync(path, "utf8"));
  // 4 and 5 are the same counter set apart from the checked-module reuse
  // class; both carry the two lane-parse counters this oracle reads.
  if (value.schema !== 4 && value.schema !== 5) fail(`unexpected telemetry schema ${JSON.stringify(value.schema)}`);
  const keys = ["modules_planned", "parse_operations", "non_walk_parse_operations", "ast_cache_prefetches"];
  // Only schema 5 carries the checked-module reuse class; the stand-down
  // scenario reads it, so validate it exactly where it is supposed to exist
  // rather than letting an absent field read as undefined.
  if (value.schema === 5) keys.push("modules_reused_checked_module_artifact");
  for (const key of keys) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`invalid ${key} in ${path}`);
  }
  return value;
}

function build(stage2, project, cache, astCache, name, checkedModuleCache = "off") {
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
      // PINNED, never inherited (#2252: a gate must not assume its
      // environment). `on` and `verify` populate
      // `checked_module_artifact_stmts`, which serves the merge before the
      // shared parse memo is consulted -- so an ambient setting would make
      // even the cache-OFF control parse nothing, and the control below
      // would fail for a reason that has nothing to do with the AST cache.
      // `tests/gates/bootstrap/run.sh` invokes this with only VIBE_RC=0.
      VIBE_CHECKED_MODULE_CACHE: checkedModuleCache,
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

    // And the prefetch must STAND DOWN where a second AST cache already
    // serves the merge. With VIBE_CHECKED_MODULE_CACHE=on,
    // `parse_program_with_path` answers from `checked_module_artifact_stmts`
    // before the shared memo, so a per-file prefetch decodes trees nothing
    // reads: measured on the full CLI closure that was +360.7 MiB (+11.3%)
    // of warm heap for 420 prefetches consumed by nothing, with
    // `non_walk_parse_operations` at 0 either way (Codex on #2771, P2).
    const artifactProject = join(work, "artifact-project");
    const artifactCache = join(work, "artifact-cache");
    makeProject(artifactProject);
    mkdirSync(artifactCache, { recursive: true });
    build(stage2, artifactProject, artifactCache, true, "artifact-cold", "on");
    const artifactWarm = build(stage2, artifactProject, artifactCache, true, "artifact-warm", "on");
    if (artifactWarm.telemetry.modules_reused_checked_module_artifact < 1) {
      fail("the checked-module artifact cache served nothing on a warm build, so the stand-down below is vacuous");
    }
    if (artifactWarm.telemetry.ast_cache_prefetches !== 0) {
      fail(`the per-file AST prefetch ran ${artifactWarm.telemetry.ast_cache_prefetches} times while the checked-module artifact cache was serving the merge: those trees are consumed by nothing`);
    }

    // An INCREMENTAL build is where the count was wrong, and it is the case
    // the counter exists for. The header pass runs from the
    // source-collection walk BEFORE the planner, so a count kept at the
    // planner reads 0 for a prefetch the header pass performed -- measured
    // exactly that way: with the stored ASTs present the merge lane parsed 0,
    // with the same ASTs deleted it parsed 1, and the counter said 0 both
    // times (Codex on #2771, P2).
    const splitProject = join(work, "split-project");
    const splitCache = join(work, "split-cache");
    makeSplitProject(splitProject);
    mkdirSync(splitCache, { recursive: true });
    build(stage2, splitProject, splitCache, true, "split-cold");
    editA(splitProject, "1");
    const edited = build(stage2, splitProject, splitCache, true, "split-edit");
    if (edited.telemetry.modules_reused < 1) {
      fail("the edit rechecked every module, so no stored AST could have served the merge and the count below proves nothing");
    }
    if (edited.telemetry.ast_cache_prefetches < 1) {
      fail("an incremental build reported ast_cache_prefetches=0; a prefetch performed by the header pass is invisible to a count kept at the planner (#2771)");
    }
    if (edited.telemetry.non_walk_parse_operations !== 0) {
      fail(`an incremental build parsed ${edited.telemetry.non_walk_parse_operations} sources in the merge lane with the AST cache on`);
    }
    // ...and the control, which is what makes the row above mean anything:
    // delete the stored ASTs and the same shape of edit DOES reach the parser.
    for (const entry of readdirSync(splitCache)) {
      if (entry.startsWith("vibe_selfhost_artifact_") && entry.endsWith(".bin")) rmSync(join(splitCache, entry));
    }
    editA(splitProject, "2");
    const withoutArtifacts = build(stage2, splitProject, splitCache, true, "split-edit-no-artifacts");
    if (withoutArtifacts.telemetry.non_walk_parse_operations < 1) {
      fail("deleting every stored AST did not make the merge lane parse, so the prefetch above was not what kept it at zero");
    }

    console.log(`ast-cache-prefetch-oracle: ok (warm prefetches=${warmOn.telemetry.ast_cache_prefetches}; merge-lane parses cold=${coldParses} warm-off=${warmOff.telemetry.non_walk_parse_operations} warm-on=${warmOn.telemetry.non_walk_parse_operations}; stands down under the checked-module artifact cache, ${artifactWarm.telemetry.modules_reused_checked_module_artifact} artifact hits; incremental prefetches=${edited.telemetry.ast_cache_prefetches}, control parses ${withoutArtifacts.telemetry.non_walk_parse_operations})`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

main();
