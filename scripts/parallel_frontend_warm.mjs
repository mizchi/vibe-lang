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

async function listDeps(runnerPath, compilerWasm, cacheDir, projectRoot, filePath) {
  const outAbs = join(cacheDir, `${filePath.replace(/[^a-zA-Z0-9]/g, "_")}.deps.out`);
  await rm(outAbs, { force: true });
  await rm(`${outAbs}.diag`, { force: true });
  const exitCode = await runVibe(
    runnerPath, compilerWasm, [filePath, outAbs, "__no_entry__"],
    { VIBE_LIST_DEPS: "1", VIBE_IMPORT_ABI: "raw" },
    projectRoot,
  );
  const diag = await readIfPresent(`${outAbs}.diag`);
  if (diag !== null) {
    throw new Error(`VIBE_LIST_DEPS failed for ${filePath}: ${diag.trim()}`);
  }
  const text = await readIfPresent(outAbs);
  if (text === null) {
    throw new Error(`VIBE_LIST_DEPS produced no output for ${filePath} (exit ${exitCode})`);
  }
  return text.split("\n").map((line) => line.trim()).filter(Boolean);
}

// Run `fn` over every item in `items`, at most `concurrency` in flight at
// once, preserving no particular completion order (callers only need the
// full result set, not ordering). A plain worker-pool loop rather than a
// library dependency, since this script has none today.
async function mapWithConcurrency(items, concurrency, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(
    Array.from({ length: Math.max(1, Math.min(concurrency, items.length)) }, worker),
  );
  return results;
}

// Level-order BFS from a single entry file, deduping by resolved path
// across the whole walk (a diamond dependency must not be scheduled twice)
// -- mirrors parallel_project_driver.mjs's discoverProject, parameterized
// by projectRoot/runnerPath instead of this repo's own fixed layout.
//
// Each BFS level (frontier) is discovered with up to `concurrency` files
// in flight at once, instead of one `vibe --invoke cli_main` subprocess
// spawn awaited fully before the next starts. On a project the size of
// the compiler's own manifest (~209 modules) the fully-serial version
// measured ~4x the plain serial-compile wall time, dominated entirely by
// this discovery loop and independent of the later parallel-check phase's
// own `jobs` count (#1168). Concurrency here reuses that same `jobs`
// value: at `jobs=1` this reduces to the original one-at-a-time walk
// (`Math.max(1, ...)` above), so a `jobs=1` run's discovery cost is
// unchanged.
async function discoverProject(runnerPath, compilerWasm, projectRoot, entryPaths, cacheDir, concurrency) {
  const modules = new Map();
  const seen = new Set(entryPaths);
  let frontier = [...entryPaths];
  while (frontier.length > 0) {
    const discovered = await mapWithConcurrency(frontier, concurrency, async (path) => {
      const [deps, source] = await Promise.all([
        listDeps(runnerPath, compilerWasm, cacheDir, projectRoot, path),
        readFile(path, "utf8"),
      ]);
      return { path, deps, source };
    });
    const nextFrontier = [];
    for (const { path, deps, source } of discovered) {
      modules.set(path, {
        id: path,
        dependencies: [...new Set(deps)],
        dependencyOccurrences: deps,
        source,
      });
      for (const dep of deps) {
        if (!seen.has(dep)) {
          seen.add(dep);
          nextFrontier.push(dep);
        }
      }
    }
    frontier = nextFrontier;
  }
  return [...modules.values()];
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

  const cacheDir = await mkdtemp(join(tmpdir(), "vibe-list-deps-"));
  let modules;
  try {
    modules = await discoverProject(runnerPath, compilerWasm, projectRoot, [entryFile], cacheDir, jobs);
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
