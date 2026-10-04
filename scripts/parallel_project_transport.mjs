// Shared compiler-owned source discovery and checked-product publication.
// Scheduler choice does not change source ingestion or persistent cache keys.
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

function runVibe(runnerPath, compilerWasm, args, env, cwd, nativeCompiler = false) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      nativeCompiler ? runnerPath : "bash",
      nativeCompiler ? [compilerWasm, ...args] : [runnerPath, "--invoke", "cli_main", compilerWasm, ...args],
      { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "ignore"] },
    );
    let stdout = "";
    child.stdout.on("data", data => { stdout = (stdout + data).slice(-65536); });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (signal) { reject(new Error(`compiler terminated with ${signal}`)); return; }
      const result = stdout.trim();
      if (nativeCompiler && result !== "" && !/^[0-9]+$/.test(result)) {
        reject(new Error(`unexpected native compiler result: ${result}`)); return;
      }
      // The bootstrap cli_main entry prints its Int result from _start;
      // the installed main entry exits instead. Honor either failure shape.
      resolvePromise(code || (nativeCompiler && /^[0-9]+$/.test(result) ? Number(result) : 0));
    });
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
export async function discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, cacheDir, nativeCompiler = false) {
  const planPath = join(cacheDir, "plan.txt");
  await rm(planPath, { force: true });
  await rm(`${planPath}.diag`, { force: true });
  const exitCode = await runVibe(
    runnerPath, compilerWasm, [entryFile, planPath, "__no_entry__"],
    { VIBE_MODULE_PLAN: "1", VIBE_IMPORT_ABI: "raw" },
    projectRoot, nativeCompiler,
  );
  const diag = await readIfPresent(`${planPath}.diag`);
  if (diag !== null) {
    throw new Error(`VIBE_MODULE_PLAN failed for ${entryFile}: ${diag.trim()}`);
  }
  if (exitCode !== 0) {
    throw new Error(`VIBE_MODULE_PLAN failed for ${entryFile} (exit ${exitCode})`);
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

// Publish every Checked outcome's complete product to the persistent cache in one
// extra wasm invocation. Diagnosed modules are simply absent from the
// manifest -- see the file header for why that is sufficient for
// correctness rather than a gap that needs its own handling.
export async function publishCheckedOutcomes(runnerPath, compilerWasm, projectRoot, outcomes, nativeCompiler = false) {
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
      const cacheFile = `cache${i}.out`;
      if (typeof artifact.cacheProduct !== "string" || artifact.cacheProduct.length === 0) {
        throw new Error("parallel frontend requires checked worker lowering products; rebuild the compiler");
      }
      await writeFile(join(publishDir, envFile), artifact.env);
      await writeFile(join(publishDir, cacheFile), artifact.cacheProduct);
      manifestLines.push(`${artifact.fingerprint}\t${envFile}\t${cacheFile}`);
    }
    await writeFile(join(publishDir, "manifest.txt"), `${manifestLines.join("\n")}\n`);
    const exitCode = await runVibe(
      runnerPath, compilerWasm,
      [publishDir, join(publishDir, "worker.out"), "__no_entry__"],
      { VIBE_PUBLISH_ENV_CACHE: "1", VIBE_IMPORT_ABI: "raw" },
      projectRoot, nativeCompiler,
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
