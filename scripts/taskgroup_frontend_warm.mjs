// Experimental native TaskGroup frontend. The host freezes source/dependency
// snapshots and publishes checked products; Vibe owns CPU worker tasks and waits.
// Ready waves are barriers. This is not yet the default build path or a claim
// that warm eligibility, independent package ownership or dynamic DAG scheduling
// is complete.
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";
import { discoverProjectViaPlan, publishCheckedOutcomes } from "./parallel_frontend_warm.mjs";
import { normalizeParallelProject } from "./parallel_scheduler_trace.mjs";
import { prepareModuleJob, readModuleJobProduct } from "./parallel_selfhost_checker.mjs";

function runCoordinator(nativeRunner, component, manifest, cwd) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(nativeRunner, [component], {
      cwd, detached: true, stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, VIBE_CHECKER_WORKERS: manifest, VIBE_CHECKER_WORKER_TRACE: "1" },
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (data) => { stdout = (stdout + data).slice(-65536); });
    child.stderr.on("data", (data) => { stderr = (stderr + data).slice(-1048576); });
    const timer = setTimeout(() => {
      try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
        if (error.code !== "ESRCH") reject(error);
      }
    }, 300000);
    const abort = () => {
      try { process.kill(-child.pid, "SIGTERM"); } catch (error) {
        if (error.code !== "ESRCH") reject(error);
      }
    };
    process.once("SIGINT", abort); process.once("SIGTERM", abort);
    const cleanup = () => {
      clearTimeout(timer);
      process.removeListener("SIGINT", abort); process.removeListener("SIGTERM", abort);
    };
    child.on("error", (error) => { cleanup(); reject(error); });
    child.on("close", (code, signal) => {
      cleanup();
      if (code !== 0) { reject(new Error(`TaskGroup coordinator exited ${code ?? signal}: ${stderr}`)); return; }
      const result = stdout.trim();
      if (!/^[0-9]+$/.test(result)) { reject(new Error(`invalid coordinator result: ${stdout}`)); return; }
      const events = stderr.split("\n").filter((line) => line.startsWith("vibe-checker-worker "))
        .map((line) => JSON.parse(line.slice("vibe-checker-worker ".length)));
      resolvePromise({ diagnosed: Number(result), events });
    });
  });
}

export async function warmTaskGroupProject({ compilerWasm, entryFile, jobs, projectRoot, runnerPath,
  workerWasm, coordinatorWasm, nativeRunner, keepWork = false }) {
  if (![1, 2, 4].includes(jobs)) throw new Error("TaskGroup jobs must be 1, 2 or 4");
  projectRoot = resolve(projectRoot);
  compilerWasm = resolve(compilerWasm); runnerPath = resolve(runnerPath);
  workerWasm = resolve(workerWasm); coordinatorWasm = resolve(coordinatorWasm); nativeRunner = resolve(nativeRunner);
  const start = performance.now();
  const timing = {};
  const work = await mkdtemp(join(tmpdir(), "vibe-taskgroup-frontend-"));
  try {
    const discoveryStart = performance.now();
    const project = await discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, work);
    const modules = normalizeParallelProject(project);
    timing.discovery_ms = performance.now() - discoveryStart;
    const pending = new Set(modules.keys());
    const outcomes = new Map();
    const waves = [];
    while (pending.size) {
      // A failed dependency is never represented by an empty success environment.
      let changed;
      do {
        changed = false;
        for (const id of pending) {
          if (modules.get(id).dependencies.some((dep) => outcomes.has(dep) && outcomes.get(dep).kind !== "checked")) {
            outcomes.set(id, { kind: "blocked" }); pending.delete(id); changed = true;
          }
        }
      } while (changed);
      if (!pending.size) break;
      const ready = [...pending].filter((id) => modules.get(id).dependencies.every((dep) => outcomes.get(dep)?.kind === "checked"))
        .sort();
      if (!ready.length) throw new Error("TaskGroup frontend has pending modules without a ready job");
      const waveStart = performance.now();
      const queues = [[], [], [], []];
      const directories = new Map();
      for (const [index, id] of ready.entries()) {
        const dir = join(work, `wave-${waves.length}-job-${index}`);
        await prepareModuleJob(dir, modules.get(id), modules.get(id).dependencies.map((dep) => ({ id: dep, outcome: outcomes.get(dep) })));
        queues[index % jobs].push(dir); directories.set(id, dir);
      }
      const manifest = join(work, `wave-${waves.length}.json`);
      await writeFile(manifest, JSON.stringify({ version: 1, wasm: workerWasm, cwd: projectRoot, queues }));
      const prepared = performance.now();
      const result = await runCoordinator(nativeRunner, coordinatorWasm, manifest, projectRoot);
      const checked = performance.now();
      let diagnosed = 0;
      for (const id of ready) {
        const module = modules.get(id);
        const product = await readModuleJobProduct(directories.get(id), module, { exit_code: 0 }, { cleanup: false });
        if (product.diagnostic) { outcomes.set(id, { kind: "diagnosed", diagnostics: [product.diagnostic] }); diagnosed++; }
        else {
          if (!product.cacheProduct) throw new Error(`worker has no checked lowering product for ${id}`);
          outcomes.set(id, { kind: "checked", artifact: { module: id, ...product } });
        }
        pending.delete(id);
      }
      if (diagnosed !== result.diagnosed) throw new Error("TaskGroup diagnostic count disagrees with committed worker outcomes");
      const read = performance.now();
      waves.push({ modules: ready.length, diagnosed, events: result.events,
        prepare_ms: prepared - waveStart, coordinator_ms: checked - prepared, read_ms: read - checked });
    }
    // Publication order is independent of completion or wave order.
    const canonical = new Map([...outcomes.entries()].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0));
    const publicationStart = performance.now();
    const warmed = await publishCheckedOutcomes(runnerPath, compilerWasm, projectRoot, canonical);
    timing.publication_ms = performance.now() - publicationStart;
    timing.prepare_ms = waves.reduce((sum, wave) => sum + wave.prepare_ms, 0);
    timing.coordinator_ms = waves.reduce((sum, wave) => sum + wave.coordinator_ms, 0);
    timing.read_ms = waves.reduce((sum, wave) => sum + wave.read_ms, 0);
    timing.total_ms = performance.now() - start;
    const counts = { checked: 0, diagnosed: 0, blocked: 0 };
    for (const outcome of canonical.values()) counts[outcome.kind]++;
    const report = { modules: modules.size, ...counts, warmed, timing, waves, ...(keepWork ? { work } : {}) };
    if (process.env.VIBE_TASKGROUP_TRACE_OUT) await writeFile(process.env.VIBE_TASKGROUP_TRACE_OUT, JSON.stringify(report));
    return report;
  } finally {
    if (!keepWork) await rm(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [compilerWasm, entryFile, count, projectRoot, runnerPath, workerWasm, coordinatorWasm, nativeRunner] = process.argv.slice(2);
  if (![compilerWasm, entryFile, count, projectRoot, runnerPath, workerWasm, coordinatorWasm, nativeRunner].every(Boolean)) {
    throw new Error("usage: taskgroup_frontend_warm.mjs <compiler> <entry> <jobs> <root> <runner-script> <worker> <coordinator> <native-runner>");
  }
  warmTaskGroupProject({ compilerWasm, entryFile, jobs: Number(count), projectRoot, runnerPath,
    workerWasm, coordinatorWasm, nativeRunner, keepWork: process.env.VIBE_TASKGROUP_KEEP_JOBS === "1" }).then((report) => {
    const { waves, ...summary } = report;
    console.log(JSON.stringify({ ...summary, waves: waves.length }));
  }).catch((error) => { console.error(String(error?.stack ?? error)); process.exitCode = 1; });
}
