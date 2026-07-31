// #906 Phase 2 (real-build wiring): pre-warm the persistent type-env cache
// for a real `vibe build`/`compile` invocation by checking the entry file's
// import DAG in parallel, then publishing every successfully-checked
// module's environment to the REAL persistent cache path via the
// VIBE_PUBLISH_ENV_CACHE adapter mode (run_publish_env_cache_dir,
// runtime/typecheck_fs.vibe).
//
// This is strictly a cache pre-warm, never a second source of truth:
// runtime/vibe always runs the serial compile_to() afterward regardless of
// what happens here, and a module that fails to check here is simply
// absent from the publish manifest -- the serial walk rechecks it from
// scratch and reports the identical diagnostic. Nothing this script does
// can change what a build produces, only how much redundant work the
// serial walk has to redo.
//
// Unlike scripts/parallel_project_driver.mjs (which pins every filesystem
// op to this repo's own directory for its test harness), every operation
// here runs with `cwd: projectRoot` and NO VIBE_PREOPEN_DIR override, to
// match exactly what an unsandboxed compile_to() does today. Introducing a
// sandbox boundary here that serial compiles don't have would silently
// change which imports resolve.
//
// CLI: node parallel_frontend_warm.mjs <compilerWasm> <entryFile> <jobs> <projectRoot> <runnerPath>
// Prints one JSON summary line to stdout on success. Any failure (bad
// arguments, a discovery error, a worker crash, a publish failure) exits
// nonzero with a message on stderr -- the caller (runtime/vibe) treats
// this whole script as advisory and always falls through to the serial
// compile regardless of its outcome.
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { runParallelProject } from "./parallel_scheduler_prototype.mjs";

function runVibe(runnerPath, compilerWasm, args, env, cwd) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      "bash",
      [runnerPath, "--invoke", "cli_main", compilerWasm, ...args],
      { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "ignore"] },
    );
    child.on("error", reject);
    child.on("exit", (code) => resolvePromise(code));
  });
}

async function readIfPresent(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

// Discover the whole import DAG in ONE compiler invocation (#1239 step
// 4(D)): VIBE_MODULE_PLAN writes a manifest of every reachable module in
// the compiler's own canonical rank order, plus each module's dependency
// list and ingested source.
//
// This replaces a per-file VIBE_LIST_DEPS spawn, which is what used to
// dominate this whole path's wall time: on this repo's own
// codegen_lexer_test.vibe graph (166 modules) the per-file loop measured
// 17.4s serially and 5.1s at 4-way concurrency, against 0.8s for the single
// plan call. The old loop also needed a per-call unique id to keep two
// concurrent listDeps invocations from racing on a sanitized-path temp file
// (#1170); here the compiler names each source file by its index in the
// manifest, so there is nothing to sanitize and nothing to collide.
//
// `source` is the module's INGESTED text, not the raw file bytes.
// ingest_source_text_fs can prepend a directory-shared import a raw .vibe
// file never had, or rewrite a contract into its facade entirely, and
// check_module parses that text -- deriving deps from one and handing back
// the other is #1168's exact bug. The compiler produces both from the same
// string (see module_plan_manifest in lib/@vibe/compiler/cli_adapter.vibe).
//
// Modules come back in rank order (rank ascending, then path), so every
// module's dependencies precede it -- runParallelProject does not require
// that, but it makes the input to a wave-at-a-time dispatcher deterministic
// regardless of how the graph was traversed.
async function discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, cacheDir) {
  const planPath = join(cacheDir, "plan.txt");
  await rm(planPath, { force: true });
  await rm(`${planPath}.diag`, { force: true });
  const exitCode = await runVibe(
    runnerPath, compilerWasm, [entryFile, planPath, "__no_entry__"],
    { VIBE_MODULE_PLAN: "1", VIBE_IMPORT_ABI: "raw" },
    projectRoot,
  );
  const diag = await readIfPresent(`${planPath}.diag`);
  if (diag !== null) {
    throw new Error(`VIBE_MODULE_PLAN failed for ${entryFile}: ${diag.trim()}`);
  }
  const manifest = await readIfPresent(planPath);
  if (manifest === null) {
    throw new Error(`VIBE_MODULE_PLAN produced no manifest for ${entryFile} (exit ${exitCode})`);
  }
  const rows = manifest.split("\n").filter(Boolean);
  if (rows[0] !== "version\t1") {
    throw new Error(`unsupported module plan version row: ${JSON.stringify(rows[0] ?? null)}`);
  }
  const paths = new Map();
  const occurrences = new Map();
  for (const row of rows.slice(1)) {
    const parts = row.split("\t");
    if (parts[0] === "module" && parts.length === 4) {
      const index = Number(parts[1]);
      paths.set(index, parts[3]);
      occurrences.set(index, []);
    } else if (parts[0] === "dep" && parts.length === 3) {
      const index = Number(parts[1]);
      const deps = occurrences.get(index);
      // A dep row for an index with no module row would silently drop that
      // dependency from the graph -- the same class of quiet wrong-graph
      // failure the ingested-source note above guards against.
      if (deps === undefined) throw new Error(`module plan dep row for unknown module index: ${row}`);
      deps.push(parts[2]);
    } else {
      throw new Error(`unknown module plan row: ${row}`);
    }
  }
  const modules = [];
  for (const index of [...paths.keys()].sort((a, b) => a - b)) {
    const source = await readIfPresent(`${planPath}.${index}.src`);
    if (source === null) {
      throw new Error(`module plan named no source for module ${index} (${paths.get(index)})`);
    }
    const dependencyOccurrences = occurrences.get(index);
    modules.push({
      id: paths.get(index),
      dependencies: [...new Set(dependencyOccurrences)],
      dependencyOccurrences,
      source,
    });
  }
  return modules;
}

// Publish every Checked outcome's env to the REAL persistent cache in one
// extra wasm invocation. Diagnosed modules are simply absent from the
// manifest -- see the file header for why that is sufficient for
// correctness rather than a gap that needs its own handling.
async function publishCheckedOutcomes(runnerPath, compilerWasm, projectRoot, outcomes) {
  const toPublish = [];
  for (const outcome of outcomes.values()) {
    if (outcome.kind === "checked" && outcome.artifact?.env) {
      toPublish.push(outcome.artifact);
    }
  }
  if (toPublish.length === 0) return 0;
  const publishDir = await mkdtemp(join(tmpdir(), "vibe-publish-env-"));
  try {
    const manifestLines = [];
    for (const [i, artifact] of toPublish.entries()) {
      const envFile = `env${i}.env`;
      await writeFile(join(publishDir, envFile), artifact.env);
      manifestLines.push(`${artifact.fingerprint}\t${envFile}`);
    }
    await writeFile(join(publishDir, "manifest.txt"), `${manifestLines.join("\n")}\n`);
    const exitCode = await runVibe(
      runnerPath, compilerWasm,
      [publishDir, join(publishDir, "worker.out"), "__no_entry__"],
      { VIBE_PUBLISH_ENV_CACHE: "1", VIBE_IMPORT_ABI: "raw" },
      projectRoot,
    );
    if (exitCode !== 0) {
      const diag = await readIfPresent(join(publishDir, "worker.out.diag"));
      throw new Error(`env cache publish failed (exit ${exitCode}): ${diag ?? "no diagnostic"}`);
    }
    return toPublish.length;
  } finally {
    await rm(publishDir, { recursive: true, force: true });
  }
}

async function main() {
  const [compilerWasm, entryFile, jobsArg, projectRoot, runnerPath] = process.argv.slice(2);
  if (!compilerWasm || !entryFile || !jobsArg || !projectRoot || !runnerPath) {
    throw new Error(
      "usage: parallel_frontend_warm.mjs <compilerWasm> <entryFile> <jobs> <projectRoot> <runnerPath>",
    );
  }
  const jobs = Number(jobsArg);
  if (!Number.isInteger(jobs) || jobs < 1) {
    throw new Error(`invalid jobs value: ${jobsArg}`);
  }

  const cacheDir = await mkdtemp(join(tmpdir(), "vibe-module-plan-"));
  let modules;
  try {
    modules = await discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, cacheDir);
  } finally {
    await rm(cacheDir, { recursive: true, force: true });
  }

  if (modules.length === 0) {
    console.log(JSON.stringify({ modules: 0, checked: 0, diagnosed: 0, warmed: 0 }));
    return;
  }

  const { outcomes } = await runParallelProject(modules, {
    jobs,
    execution: { kind: "selfhost-check", compilerWasm, runnerPath },
  });

  let checked = 0;
  let diagnosed = 0;
  for (const outcome of outcomes.values()) {
    if (outcome.kind === "checked") checked++;
    else diagnosed++;
  }
  const warmed = await publishCheckedOutcomes(runnerPath, compilerWasm, projectRoot, outcomes);
  console.log(JSON.stringify({ modules: modules.length, checked, diagnosed, warmed }));
}

main().catch((error) => {
  console.error(String(error?.stack ?? error));
  process.exit(1);
});
