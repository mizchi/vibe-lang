// #906 Phase 2 (real-build wiring): pre-warm the persistent type-env cache
// for a real `vibe build`/`compile` invocation by checking the entry file's
// import DAG in parallel, then publishing every successfully-checked
// module's environment and lowering product to the REAL persistent cache via the
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
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { runParallelProject } from "./parallel_scheduler_prototype.mjs";

export { discoverProjectViaPlan, publishCheckedOutcomes } from "./parallel_project_transport.mjs";
import { discoverProjectViaPlan, publishCheckedOutcomes } from "./parallel_project_transport.mjs";

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

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(String(error?.stack ?? error));
    process.exit(1);
  });
}
