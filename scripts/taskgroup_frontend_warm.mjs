// Experimental native TaskGroup frontend. The host freezes source/dependency
// snapshots and publishes checked products; Vibe owns CPU worker tasks and waits.
// Ready waves are barriers. This is not yet the default build path or a claim
// that warm eligibility, independent package ownership or dynamic DAG scheduling
// is complete.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";
import { discoverProjectViaPlan, publishCheckedOutcomes } from "./parallel_project_transport.mjs";
import { normalizeParallelProject } from "./parallel_scheduler_trace.mjs";
import { moduleJobInputs, writeModuleJobInputs, readModuleJobProduct } from "./parallel_selfhost_checker.mjs";
import { TaskGroupJobCache } from "./taskgroup_job_cache.mjs";

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

function sha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function checkedEnvironmentDigest(digests, outcomes, path) {
  if (!digests.has(path)) {
    const env = outcomes.get(path)?.artifact?.env;
    if (typeof env !== "string" || !env.length) throw new Error(`missing checked environment for ${path}`);
    digests.set(path, sha256(env));
  }
  return digests.get(path);
}

function checkerJobCacheKey(cache, inputs, module, outcomes, interfaceDigests) {
  if (!cache) return null;
  if (!interfaceDigests) return cache.inputKey(inputs);
  const paths = module.dependencyOccurrences ?? module.dependencies;
  const dependencies = paths.map((path, index) =>
    [`dep${index}.env`, checkedEnvironmentDigest(interfaceDigests, outcomes, path)]);
  return cache.inputKey([...inputs.slice(0, 2), ...dependencies], true);
}

// The final compiler validates canonical encoding and binds each product to
// the fingerprint from its own walk. Check that the worker's two views agree
// before handing over the combined product, as in persistent publication.
async function stageCheckedProducts(directory, outcomes, modules, interfaceDigests) {
  await mkdir(directory);
  const typingContext = interfaceDigests
    ? `${process.env.VIBE_CHECK_ERROR_ROW === "0" ? "legacy" : "checked"}\t${sha256(process.env.VIBE_CFG ?? "")}`
    : "";
  for (const { artifact } of outcomes.values()) {
    const { module, env, cacheProduct, fingerprint } = artifact;
    const envHeader = "version\t10\n";
    const productHeader = `checked-worker-cache\t1\t${fingerprint}\nversion\t11\n`;
    if (!env.startsWith(envHeader) || !cacheProduct.startsWith(productHeader + env.slice(envHeader.length))) {
      throw new Error(`TaskGroup checked product disagrees with its environment: ${module}`);
    }
    const file = sha256(module);
    let product = cacheProduct;
    if (interfaceDigests) {
      const { source, dependencies, dependencyOccurrences } = modules.get(module);
      const rows = [`checked-worker-interface-cache\t1\t${typingContext}\t${sha256(source)}`];
      for (const dep of dependencyOccurrences ?? dependencies) {
        rows.push(`dep\t${sha256(dep)}\t${checkedEnvironmentDigest(interfaceDigests, outcomes, dep)}`);
      }
      const payload = cacheProduct.slice(cacheProduct.indexOf("\n") + 1);
      product = rows.join("\n") + "\n\n" + payload;
    }
    await writeFile(join(directory, file), product, { encoding: "utf8", flag: "wx" });
  }
  return outcomes.size;
}

// A separate, short-lived process publishes the replay records only after
// the final compiler exits successfully. It uses the keys and image context
// captured during preparation, independent of the final compiler's environment.
export async function commitDirectReplay(work) {
  const { cache, fresh } = JSON.parse(await readFile(join(work, "pending-replay.json"), "utf8"));
  if (await readFile(join(work, "checked-products", "accepted"), "utf8") !== "checked-taskgroup-v1") {
    throw new Error("invalid TaskGroup checked-product receipt");
  }
  if (!Array.isArray(fresh) || !fresh.every(([key, dir]) => /^[a-f0-9]{64}$/.test(key) && /^wave-[0-9]+-job-[0-9]+$/.test(dir))) {
    throw new Error("invalid pending TaskGroup replay");
  }
  const replay = new TaskGroupJobCache(cache.root, cache.images, cache.hashes, cache.context);
  await replay.verifyImages();
  for (const [key, dir] of fresh) await replay.store(key, join(work, dir));
}

export async function warmTaskGroupProject({ compilerWasm, entryFile, jobs, projectRoot, runnerPath,
  workerWasm, coordinatorWasm, nativeRunner, keepWork = false, nativeCompiler = false, directWork }) {
  if (![1, 2, 4].includes(jobs)) throw new Error("TaskGroup jobs must be 1, 2 or 4");
  projectRoot = resolve(projectRoot);
  compilerWasm = resolve(compilerWasm); runnerPath = resolve(runnerPath);
  workerWasm = resolve(workerWasm); coordinatorWasm = resolve(coordinatorWasm); nativeRunner = resolve(nativeRunner);
  const interfaceReplay = process.env.VIBE_TASKGROUP_INTERFACE_REPLAY === "1";
  if (interfaceReplay && !directWork) throw new Error("interface replay requires direct checked-product handoff");
  const interfaceDigests = interfaceReplay ? new Map() : null;
  const start = performance.now();
  const timing = {};
  const cache = process.env.VIBE_TASKGROUP_JOB_CACHE === "1" ? await TaskGroupJobCache.create(projectRoot,
    [compilerWasm, workerWasm, coordinatorWasm, nativeRunner]) : null;
  const fresh = [];
  let executed = 0, reused = 0;
  const work = directWork ? resolve(directWork) : await mkdtemp(join(tmpdir(), "vibe-taskgroup-frontend-"));
  try {
    const discoveryStart = performance.now();
    const modules = normalizeParallelProject(
      await discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, work, nativeCompiler),
    );
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
      const cached = new Map(), keys = new Map();
      let misses = 0;
      for (const [index, id] of ready.entries()) {
        const dir = join(work, `wave-${waves.length}-job-${index}`);
        const inputs = moduleJobInputs(modules.get(id), modules.get(id).dependencies.map((dep) => ({ id: dep, outcome: outcomes.get(dep) })));
        directories.set(id, dir);
        const key = checkerJobCacheKey(cache, inputs, modules.get(id), outcomes, interfaceDigests);
        keys.set(id, key);
        const product = cache ? await cache.lookup(key, modules.get(id)) : null;
        if (product) { cached.set(id, product); reused++; }
        else {
          await writeModuleJobInputs(dir, inputs);
          queues[misses % jobs].push(dir); misses++; executed++;
        }
      }
      const manifest = join(work, `wave-${waves.length}.json`);
      await writeFile(manifest, JSON.stringify({ version: 1, wasm: workerWasm, cwd: projectRoot, queues }));
      const prepared = performance.now();
      const result = misses ? await runCoordinator(nativeRunner, coordinatorWasm, manifest, projectRoot)
        : { diagnosed: 0, events: [] };
      const checked = performance.now();
      let diagnosed = 0;
      for (const id of ready) {
        const module = modules.get(id);
        const product = cached.get(id) ?? await readModuleJobProduct(directories.get(id), module, { exit_code: 0 }, { cleanup: false });
        if (product.diagnostic) { outcomes.set(id, { kind: "diagnosed", diagnostics: [product.diagnostic] }); diagnosed++; }
        else {
          if (!product.cacheProduct) throw new Error(`worker has no checked lowering product for ${id}`);
          outcomes.set(id, { kind: "checked", artifact: { module: id, ...product } });
          if (cache && !cached.has(id)) fresh.push([keys.get(id), directories.get(id)]);
        }
        pending.delete(id);
      }
      if (diagnosed !== result.diagnosed) throw new Error("TaskGroup diagnostic count disagrees with committed worker outcomes");
      const read = performance.now();
      waves.push({ modules: ready.length, executed: misses, reused: cached.size, diagnosed, events: result.events,
        prepare_ms: prepared - waveStart, coordinator_ms: checked - prepared, read_ms: read - checked });
    }
    // Publication order is independent of completion or wave order.
    const canonical = new Map([...outcomes.entries()].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0));
    const publicationStart = performance.now();
    if (cache) await cache.verifyImages();
    const counts = { checked: 0, diagnosed: 0, blocked: 0 };
    for (const outcome of canonical.values()) counts[outcome.kind]++;
    const moduleCount = modules.size;
    // Preserve the final compiler's diagnostics on rejected snapshots: only
    // completely checked graphs have the products required by the direct walk.
    const directory = directWork && counts.checked === moduleCount ? join(work, "checked-products") : "";
    const warmed = directory
      ? await stageCheckedProducts(directory, canonical, modules, interfaceDigests)
      : await publishCheckedOutcomes(runnerPath, compilerWasm, projectRoot, canonical, nativeCompiler);
    // Published products have already been validated by a compiler.
    if (!directory && cache) for (const [key, dir] of fresh) await cache.store(key, dir);
    if (directory && fresh.length > 0) {
      await writeFile(join(work, "pending-replay.json"), JSON.stringify({
        cache,
        fresh: fresh.map(([key, dir]) => [key, basename(dir)]),
      }));
    }
    timing.publication_ms = performance.now() - publicationStart;
    timing.prepare_ms = waves.reduce((sum, wave) => sum + wave.prepare_ms, 0);
    timing.coordinator_ms = waves.reduce((sum, wave) => sum + wave.coordinator_ms, 0);
    timing.read_ms = waves.reduce((sum, wave) => sum + wave.read_ms, 0);
    timing.total_ms = performance.now() - start;
    const report = { modules: moduleCount, ...counts, executed, reused, warmed, timing, waves,
      handoff: directory ? "direct" : "published", interface_replay: interfaceReplay, ...(keepWork ? { work } : {}) };
    if (process.env.VIBE_TASKGROUP_TRACE_OUT) await writeFile(process.env.VIBE_TASKGROUP_TRACE_OUT, JSON.stringify(report));
    return report;
  } finally {
    if (!directWork && !keepWork) await rm(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const request = process.argv.slice(2);
  if (request[0] === "--commit-direct" && request.length === 2) {
    commitDirectReplay(request[1]).catch(error => { console.error(error.message); process.exitCode = 1; });
  } else {
    const [compilerWasm, entryFile, count, projectRoot, runnerPath, workerWasm, coordinatorWasm,
      nativeRunner, transport, directWork] = request;
    if (![compilerWasm, entryFile, count, projectRoot, runnerPath, workerWasm, coordinatorWasm, nativeRunner].every(Boolean) ||
        (transport === "direct" && !directWork)) {
      throw new Error("usage: taskgroup_frontend_warm.mjs <compiler> <entry> <jobs> <root> <runner-script> <worker> <coordinator> <native-runner> [native | direct <work>]");
    }
    warmTaskGroupProject({ compilerWasm, entryFile, jobs: Number(count), projectRoot, runnerPath,
      workerWasm, coordinatorWasm, nativeRunner, nativeCompiler: transport === "native",
      keepWork: process.env.VIBE_TASKGROUP_KEEP_JOBS === "1", directWork }).then(report => {
      const { waves, ...summary } = report;
      console.log(JSON.stringify({ ...summary, waves: waves.length }));
    }).catch(error => { console.error(String(error?.stack ?? error)); process.exitCode = 1; });
  }
}
