// Experimental native TaskGroup frontend. The host freezes source/dependency
// snapshots and publishes checked products; Vibe owns CPU worker tasks and waits.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { createInterface } from "node:readline";
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

function startCoordinatorSession(nativeRunner, component, worker, cwd, readySlots) {
  const args = readySlots ? ["--checker-ready-session", component, worker, String(readySlots)]
    : ["--checker-session", component, worker];
  const child = spawn(nativeRunner, args, { cwd, detached: true, stdio: ["pipe", "pipe", "pipe"] });
  const replies = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const pending = new Map();
  let stderr = "", failure, nextId = 0, exited;
  child.stderr.on("data", data => { stderr = (stderr + data).slice(-1048576); });
  const stop = () => child.kill("SIGKILL");
  const fail = error => { failure ??= error; stop(); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
  child.stdin.on("error", fail);
  child.on("error", error => { failure ??= error; });
  replies.on("line", line => {
    try {
      const result = JSON.parse(line);
      const id = readySlots ? result.id : pending.keys().next().value;
      const request = pending.get(id);
      if (!request || !Number.isSafeInteger(result.diagnosed) || result.diagnosed < 0 || !Array.isArray(result.events)) {
        throw new Error("invalid TaskGroup coordinator session result");
      }
      pending.delete(id);
      request.resolve(result);
    } catch (error) {
      fail(error);
    }
  });
  const closed = new Promise(resolveClose => child.once("close", (code, signal) => {
    process.removeListener("SIGINT", stop); process.removeListener("SIGTERM", stop);
    exited = new Error(`TaskGroup coordinator session exited ${code ?? signal}: ${stderr || failure?.message || ""}`);
    for (const request of pending.values()) request.reject(exited);
    const incomplete = pending.size > 0;
    pending.clear();
    resolveClose(code === 0 && !failure && !incomplete ? null : exited);
  }));
  return {
    async check(manifest) {
      if (exited) throw exited;
      const id = nextId++;
      const timer = setTimeout(stop, 300000);
      try {
        return await new Promise((resolveResult, reject) => {
          pending.set(id, { resolve: resolveResult, reject });
          child.stdin.write(JSON.stringify(readySlots ? { id, manifest } : manifest) + "\n");
        });
      } finally {
        clearTimeout(timer);
      }
    },
    async finish() {
      const timer = setTimeout(stop, 300000);
      try {
        child.stdin.end();
        const error = await closed;
        if (error) throw error;
      } finally {
        clearTimeout(timer);
      }
    },
    async abort() {
      stop();
      await closed;
    },
  };
}

// Resolve readiness only from validated products. Propagate diagnoses to all
// consumers while leaving independent work eligible for checking.
async function dispatchReady({ modules, jobs, work, cache, outcomes, fresh, workerWasm, projectRoot, check }) {
  const dependents = new Map([...modules.keys()].map(id => [id, []]));
  const remaining = new Map();
  const ready = [];
  for (const { id, dependencies } of modules.values()) {
    remaining.set(id, dependencies.length);
    for (const dep of dependencies) dependents.get(dep).push(id);
    if (!dependencies.length) ready.push(id);
  }

  function complete(id, outcome) {
    const resolved = [[id, outcome]];
    while (resolved.length) {
      const [key, result] = resolved.pop();
      if (outcomes.has(key)) continue;
      outcomes.set(key, result);
      for (const dep of dependents.get(key)) {
        if (result.kind !== "checked") {
          resolved.push([dep, { kind: "blocked" }]);
        } else {
          const count = remaining.get(dep) - 1;
          remaining.set(dep, count);
          if (!count && !outcomes.has(dep)) ready.push(dep);
        }
      }
    }
  }

  function accept(id, product) {
    if (product.diagnostic) {
      complete(id, { kind: "diagnosed", diagnostics: [product.diagnostic] });
      return 1;
    }
    if (!product.cacheProduct) throw new Error(`worker has no checked lowering product for ${id}`);
    complete(id, { kind: "checked", artifact: { module: id, ...product } });
    return 0;
  }

  let executed = 0, reused = 0, sequence = 0;
  const waves = [], active = new Map();
  while (ready.length || active.size) {
    while (ready.length && active.size < jobs) {
      ready.sort();
      const count = Math.min(16, Math.ceil(ready.length / (jobs - active.size)));
      const misses = [], batch = sequence++, preparing = performance.now();
      let hits = 0;
      for (const [index, id] of ready.splice(0, count).entries()) {
        if (outcomes.has(id)) continue;
        const module = modules.get(id);
        const dir = join(work, `wave-${batch}-job-${index}`);
        const inputs = moduleJobInputs(module, module.dependencies.map(dep => ({ id: dep, outcome: outcomes.get(dep) })));
        const key = cache ? cache.inputKey(inputs) : null;
        const cached = cache ? await cache.lookup(key, module) : null;
        if (cached) {
          accept(id, cached);
          hits++;
        } else {
          await writeModuleJobInputs(dir, inputs);
          misses.push({ id, dir, key });
        }
      }
      reused += hits;
      executed += misses.length;
      const trace = { modules: misses.length + hits, executed: misses.length, reused: hits, diagnosed: 0, events: [],
        prepare_ms: 0, coordinator_ms: 0, read_ms: 0 };
      if (trace.modules) waves.push(trace);
      if (misses.length) {
        const manifest = join(work, `wave-${batch}.json`);
        await writeFile(manifest, JSON.stringify({
          version: 1, wasm: workerWasm, cwd: projectRoot, queues: [misses.map(({ dir }) => dir), [], [], []],
        }));
        const submitted = performance.now();
        trace.prepare_ms = submitted - preparing;
        active.set(batch, check(manifest).then(
          result => ({ batch, misses, trace, result, elapsed: performance.now() - submitted }),
          error => ({ batch, error }),
        ));
      } else {
        trace.prepare_ms = performance.now() - preparing;
      }
    }
    if (!active.size) continue;
    const completed = await Promise.race(active.values());
    if (completed.error) throw completed.error;
    const { batch, misses, trace, result, elapsed } = completed;
    active.delete(batch);
    const reading = performance.now();
    for (const { id, dir, key } of misses) {
      const product = await readModuleJobProduct(dir, modules.get(id), { exit_code: 0 }, { cleanup: false });
      if (!accept(id, product) && cache) fresh.push([key, dir]);
      if (product.diagnostic) trace.diagnosed++;
    }
    if (trace.diagnosed !== result.diagnosed) throw new Error("TaskGroup diagnostic count disagrees with committed worker outcomes");
    Object.assign(trace, { events: result.events, coordinator_ms: elapsed, read_ms: performance.now() - reading,
      dispatched: misses.map(({ id }) => id) });
  }
  if (outcomes.size !== modules.size) throw new Error("TaskGroup frontend has pending modules without a ready job");
  return { waves, executed, reused };
}

// The final compiler validates canonical encoding and binds each product to
// the fingerprint from its own walk. Check that the worker's two views agree
// before handing over the combined product, as in persistent publication.
async function stageCheckedProducts(directory, outcomes) {
  await mkdir(directory);
  for (const { artifact } of outcomes.values()) {
    const { module, env, cacheProduct, fingerprint } = artifact;
    const envHeader = "version\t10\n";
    const productHeader = `checked-worker-cache\t1\t${fingerprint}\nversion\t11\n`;
    if (!env.startsWith(envHeader) || !cacheProduct.startsWith(productHeader + env.slice(envHeader.length))) {
      throw new Error(`TaskGroup checked product disagrees with its environment: ${module}`);
    }
    const file = createHash("sha256").update(module, "utf8").digest("hex");
    await writeFile(join(directory, file), cacheProduct, { encoding: "utf8", flag: "wx" });
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
  const coordinator = process.env.VIBE_CHECKER_COORDINATOR ?? "wave";
  if (coordinator !== "wave" && coordinator !== "session") throw new Error("VIBE_CHECKER_COORDINATOR must be wave or session");
  if (coordinator === "session" && process.env.VIBE_CHECKER_WORKER_BACKEND !== "thread") {
    throw new Error("the checker session requires VIBE_CHECKER_WORKER_BACKEND=thread");
  }
  const schedule = process.env.VIBE_CHECKER_SCHEDULE ?? "waves";
  if (schedule !== "waves" && schedule !== "ready") throw new Error("VIBE_CHECKER_SCHEDULE must be waves or ready");
  if (schedule === "ready" && coordinator !== "session") throw new Error("ready dispatch requires VIBE_CHECKER_COORDINATOR=session");
  const start = performance.now();
  const timing = {};
  const cache = process.env.VIBE_TASKGROUP_JOB_CACHE === "1" ? await TaskGroupJobCache.create(projectRoot,
    [compilerWasm, workerWasm, coordinatorWasm, nativeRunner]) : null;
  const fresh = [];
  let executed = 0, reused = 0;
  let session;
  const work = directWork ? resolve(directWork) : await mkdtemp(join(tmpdir(), "vibe-taskgroup-frontend-"));
  try {
    const discoveryStart = performance.now();
    const modules = normalizeParallelProject(
      await discoverProjectViaPlan(runnerPath, compilerWasm, projectRoot, entryFile, work, nativeCompiler),
    );
    timing.discovery_ms = performance.now() - discoveryStart;
    const dispatchStarted = performance.now();
    const pending = new Set(schedule === "waves" ? modules.keys() : []);
    const outcomes = new Map();
    let waves = [];
    if (schedule === "ready") {
      ({ waves, executed, reused } = await dispatchReady({ modules, jobs, work, cache, outcomes, fresh, workerWasm, projectRoot,
        check: manifest => {
          session ??= startCoordinatorSession(nativeRunner, coordinatorWasm, workerWasm, projectRoot, jobs);
          return session.check(manifest);
        },
      }));
    }
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
        const key = cache ? cache.inputKey(inputs) : null;
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
      let result = { diagnosed: 0, events: [] };
      if (misses && coordinator === "session") {
        session ??= startCoordinatorSession(nativeRunner, coordinatorWasm, workerWasm, projectRoot);
        result = await session.check(manifest);
      } else if (misses) {
        result = await runCoordinator(nativeRunner, coordinatorWasm, manifest, projectRoot);
      }
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
    if (session) {
      const closing = performance.now();
      await session.finish();
      session = undefined;
      timing.coordinator_shutdown_ms = performance.now() - closing;
    }
    timing.dispatch_ms = performance.now() - dispatchStarted;
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
      ? await stageCheckedProducts(directory, canonical)
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
    const report = { modules: moduleCount, ...counts, executed, reused, warmed, timing, waves, coordinator, schedule,
      handoff: directory ? "direct" : "published", ...(keepWork ? { work } : {}) };
    if (process.env.VIBE_TASKGROUP_TRACE_OUT) await writeFile(process.env.VIBE_TASKGROUP_TRACE_OUT, JSON.stringify(report));
    return report;
  } finally {
    await session?.abort();
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
