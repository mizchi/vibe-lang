// #906: the missing half of the worker transport -- a host-side driver that
// discovers a REAL project's import DAG from files on disk, instead of only
// the synthetic in-memory module lists parallel_scheduler_selfhost.test.mjs
// builds by hand.
//
// This is discovery-only. It is not wired into `vibe build`, there is no
// `--jobs` flag, and no timing claim is made here -- see
// docs/compiler-parallelism.md for what's still missing before either of
// those is true.
//
// Discovery reuses the compiler's OWN import resolution (VIBE_LIST_DEPS,
// which calls load_or_parse_module_header_fs -- the exact primitive
// ensure_fingerprint_fs_go's serial walk uses) rather than re-deriving "how
// an import path resolves" here. A second implementation of that logic is
// the same drift risk the #906 fingerprint fix (ModuleJob.dep_fps) closed
// for cache keys: getting it wrong wouldn't fail loudly, it would silently
// walk the wrong graph.
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import { runParallelProject } from "./parallel_scheduler_prototype.mjs";

const ROOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNNER_PATH = join(ROOT_DIR, "scripts", "run_wasm_vibe_host_runner.sh");

function runVibe(compilerWasm, args, env) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      "bash",
      [RUNNER_PATH, "--invoke", "cli_main", compilerWasm, ...args],
      { cwd: ROOT_DIR, env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "ignore"] },
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

async function listDeps(compilerWasm, cacheDir, filePath) {
  const outPath = `${filePath.replace(/[^a-zA-Z0-9]/g, "_")}.deps.out`;
  const outAbs = join(cacheDir, outPath);
  await rm(outAbs, { force: true });
  await rm(`${outAbs}.diag`, { force: true });
  const exitCode = await runVibe(compilerWasm, [filePath, outAbs, "__no_entry__"], {
    VIBE_PREOPEN_DIR: ROOT_DIR,
    VIBE_LIST_DEPS: "1",
    VIBE_IMPORT_ABI: "raw",
    VIBE_BUILD_CACHE_DIR: join(cacheDir, "cache"),
  });
  const diag = await readIfPresent(`${outAbs}.diag`);
  if (diag !== null) {
    throw new Error(`VIBE_LIST_DEPS failed for ${filePath}: ${diag.trim()}`);
  }
  const text = await readIfPresent(outAbs);
  if (text === null) {
    throw new Error(`VIBE_LIST_DEPS produced no output for ${filePath} (exit ${exitCode})`);
  }
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

// Discover the whole reachable module set from `entryPaths` (absolute
// paths), BFS over resolved dependency edges. Real project graphs are
// rarely trees -- a diamond (one leaf reached through two importers) is
// the norm, not the edge case -- so this dedupes by RESOLVED path in a
// single `seen` set shared across the whole walk, never by which importer
// mentioned a dependency first.
export async function discoverProject(compilerWasm, entryPaths) {
  const cacheDir = await mkdtemp(join(tmpdir(), "vibe-list-deps-"));
  try {
    const modules = new Map();
    const seen = new Set(entryPaths);
    const queue = [...entryPaths];
    while (queue.length > 0) {
      const path = queue.shift();
      const [deps, source] = await Promise.all([
        listDeps(compilerWasm, cacheDir, path),
        readFile(path, "utf8"),
      ]);
      modules.set(path, { id: path, dependencies: deps, source });
      for (const dep of deps) {
        if (!seen.has(dep)) {
          seen.add(dep);
          queue.push(dep);
        }
      }
    }
    return [...modules.values()];
  } finally {
    await rm(cacheDir, { recursive: true, force: true });
  }
}

// Discover + check a real on-disk project through the worker pool.
export async function checkProjectParallel(compilerWasm, entryPaths, jobs) {
  const modules = await discoverProject(compilerWasm, entryPaths);
  return runParallelProject(modules, {
    jobs,
    execution: { kind: "selfhost-check", compilerWasm },
  });
}
