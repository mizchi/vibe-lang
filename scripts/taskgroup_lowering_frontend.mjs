// Vibe owns each wave's task lifetime. The host bounds serialized inputs and
// only publishes the compiler result after source-order replay succeeds.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";

const LIMIT_BYTES = 64 * 1024 * 1024, LIMIT_JOBS = 16;

// Resolve existing symlinks even when the final file or its parent is absent.
async function canonicalDestination(path) {
  try { return await realpath(path); }
  catch (e) {
    if (e.code !== "ENOENT") throw e;
    return join(await canonicalDestination(dirname(path)), basename(path));
  }
}

async function refuseTraceAlias(trace, destination, label = "build output") {
  if (await canonicalDestination(trace) === await canonicalDestination(destination)) {
    throw new Error(`lowering trace must not alias the ${label}`);
  }
  const info = async path => {
    try { return await stat(path); }
    catch (e) { if (e.code !== "ENOENT") throw e; return null; }
  };
  const [a, b] = await Promise.all([info(trace), info(destination)]);
  if (a && b && a.dev === b.dev && a.ino === b.ino) {
    throw new Error(`lowering trace must not alias the ${label}`);
  }
}

async function refuseUnrelatedTrace(trace) {
  let text;
  try { text = await readFile(trace, "utf8"); }
  catch (e) { if (e.code === "ENOENT") return; throw e; }
  let previous;
  try { previous = JSON.parse(text); } catch { /* Existing source or other data. */ }
  if (previous?.kind !== "vibe-taskgroup-lowering" || previous.version !== 1) {
    throw new Error("lowering trace already exists and is not a lowering report; choose a new trace path");
  }
}

function run(runner, image, cwd, env) {
  return new Promise((yes, no) => {
    const child = spawn(runner, [image], { cwd, detached: true,
      stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...env } });
    let stdout = "", stderr = "";
    child.stdout.on("data", b => { stdout = (stdout + b).slice(-65536); });
    child.stderr.on("data", b => { stderr = (stderr + b).slice(-65536); });
    const kill = signal => {
      try { process.kill(-child.pid, signal); } catch (e) { if (e.code !== "ESRCH") no(e); }
    };
    const abort = () => kill("SIGTERM");
    const timer = setTimeout(() => kill("SIGKILL"), 300000);
    process.once("SIGINT", abort); process.once("SIGTERM", abort);
    const cleanup = () => {
      clearTimeout(timer); process.removeListener("SIGINT", abort); process.removeListener("SIGTERM", abort);
    };
    child.on("error", e => { cleanup(); no(e); });
    child.on("close", (code, signal) => {
      cleanup();
      if (code !== 0) no(new Error(`lowering ${image} exited ${code ?? signal}: ${stderr}`));
      else yes(stdout.trim());
    });
  });
}

export async function buildTaskGroupLowering({ compiler, input, output, entry, jobs, root, artifacts, runner }) {
  if (![1, 2, 4].includes(jobs)) throw new Error("lowering jobs must be 1, 2 or 4");
  root = resolve(root); artifacts = resolve(artifacts); runner = resolve(runner);
  const destination = resolve(root, output);
  const trace = process.env.VIBE_LOWERING_TRACE_OUT ? resolve(root, process.env.VIBE_LOWERING_TRACE_OUT) : null;
  if (trace) {
    await refuseTraceAlias(trace, destination);
    await refuseTraceAlias(trace, resolve(root, input), "source entry");
    await refuseUnrelatedTrace(trace);
    await rm(trace, { force: true });
  }
  const digest = async p => createHash("sha256").update(await readFile(p)).digest("hex");
  const receipt = JSON.parse(await readFile(join(artifacts, "build.json"), "utf8"));
  if (receipt.version !== 1 || receipt.compiler_sha256 !== await digest(resolve(compiler)) ||
      receipt.runner_sha256 !== await digest(runner)) throw new Error("rebuild lowering images for this compiler and runner");
  for (const name of ["worker.wasm", "compile.wasm", "coordinator.component.wasm"]) {
    if (receipt.artifacts[name] !== await digest(join(artifacts, name))) throw new Error(`lowering image changed: ${name}`);
  }
  const work = await mkdtemp(join(tmpdir(), "vibe-lowering-")), started = performance.now();
  const base = { VIBE_LOWERING_INPUT: input, VIBE_LOWERING_ENTRY: entry,
    VIBE_LOWERING_DIRECTORY: work, VIBE_PREOPEN_DIR: root, VIBE_IMPORT_ABI: "raw" };
  try {
    const privateOutput = join(work, "result.wasm");
    await run(runner, join(artifacts, "compile.wasm"), root, { ...base, VIBE_LOWERING_MODE: "prepare" });
    const prepared = performance.now();
    const rows = (await readFile(join(work, "jobs.tsv"), "utf8")).split("\n").map(row => {
      const cols = row.split("\t");
      if (cols.length !== 2 || !/^[0-9a-f]{64}$/.test(cols[1])) throw new Error("malformed lowering receipt");
      return cols[0];
    });
    const sizes = await Promise.all(rows.map(async p => (await stat(p)).size));
    let next = 0, peakBytes = 0, peakJobs = 0;
    const waves = [];
    while (next < rows.length) {
      const queues = [[], [], [], []], weights = [0, 0, 0, 0];
      let bytes = 0, count = 0;
      while (next < rows.length) {
        const size = sizes[next];
        if (size > LIMIT_BYTES) throw new Error("one lowering job exceeds 64 MiB");
        const available = weights.slice(0, jobs).map((weight, slot) => ({ weight, slot }))
          .filter(x => queues[x.slot].length < LIMIT_JOBS).sort((a, b) => a.weight - b.weight);
        if (!available.length || bytes + size > LIMIT_BYTES) break;
        const slot = available[0].slot;
        queues[slot].push(rows[next++]); weights[slot] += size; bytes += size; count++;
      }
      if (!count) throw new Error("lowering wave made no progress");
      const manifest = join(work, `wave-${waves.length}.json`);
      await writeFile(manifest, JSON.stringify({ version: 1, wasm: join(artifacts, "worker.wasm"), cwd: root, queues }));
      const before = performance.now();
      const completed = await run(runner, join(artifacts, "coordinator.component.wasm"), root,
        { ...base, VIBE_LOWERING_WORKERS: manifest });
      if (completed !== String(count)) throw new Error("lowering coordinator returned an incomplete wave");
      for (const path of queues.flat()) {
        if (!(await stat(path + ".product")).size) throw new Error("lowering worker has no product");
        await rm(path);
      }
      peakBytes = Math.max(peakBytes, bytes); peakJobs = Math.max(peakJobs, count);
      waves.push({ jobs: count, input_bytes: bytes, wall_ms: performance.now() - before });
    }
    const lowered = performance.now();
    await run(runner, join(artifacts, "compile.wasm"), root,
      { ...base, VIBE_LOWERING_MODE: "replay", VIBE_LOWERING_OUTPUT: privateOutput });
    if (receipt.compiler_sha256 !== await digest(resolve(compiler)) || receipt.runner_sha256 !== await digest(runner)) {
      throw new Error("compiler or runner changed during lowering");
    }
    for (const name of ["worker.wasm", "compile.wasm", "coordinator.component.wasm"]) {
      if (receipt.artifacts[name] !== await digest(join(artifacts, name))) throw new Error(`lowering image changed during build: ${name}`);
    }
    const result = await readFile(privateOutput);
    if (!WebAssembly.validate(result)) throw new Error("lowering produced invalid core Wasm");
    // Preserve an existing target if any phase failed; temp publication avoids
    // exposing partial compiler output or products.
    const { rename } = await import("node:fs/promises");
    await mkdir(dirname(destination), { recursive: true });
    const staging = destination + `.lowering-${process.pid}.tmp`;
    let traceWritten = false, published = false, traceStaging = null;
    try {
      await writeFile(staging, result);
      const finished = performance.now();
      const report = { version: 1, kind: "vibe-taskgroup-lowering",
        modules: rows.length, workers: jobs, peak_queued_jobs: peakJobs,
        peak_queued_input_bytes: peakBytes, prepare_ms: prepared - started,
        worker_ms: lowered - prepared, replay_ms: finished - lowered,
        total_ms: finished - started, waves };
      if (trace) {
        await refuseTraceAlias(trace, destination);
        await refuseTraceAlias(trace, resolve(root, input), "source entry");
        await refuseUnrelatedTrace(trace);
        traceStaging = await mkdtemp(join(dirname(trace), ".vibe-lowering-trace-"));
        const stagedReport = join(traceStaging, "report.json");
        await writeFile(stagedReport, JSON.stringify(report));
        await rename(stagedReport, trace);
        traceWritten = true;
        // Once created, an absent case-folded alias can be checked by inode.
        await refuseTraceAlias(trace, destination);
        await refuseTraceAlias(trace, resolve(root, input), "source entry");
      }
      await rename(staging, destination);
      published = true;
      return report;
    } finally {
      await rm(staging, { force: true });
      if (traceStaging) await rm(traceStaging, { recursive: true, force: true });
      if (traceWritten && !published) await rm(trace, { force: true });
    }
  } finally { await rm(work, { recursive: true, force: true }); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [compiler, input, output, entry, count, root, artifacts, runner] = process.argv.slice(2);
  buildTaskGroupLowering({ compiler, input, output, entry, jobs: Number(count), root, artifacts, runner })
    .catch(e => { console.error(`build --jobs lowering: ${e.message}`); process.exitCode = 1; });
}
