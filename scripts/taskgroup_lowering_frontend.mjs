// Vibe owns each wave's task lifetime. The host bounds serialized inputs and
// only publishes the compiler result after source-order replay succeeds.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";


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

async function refuseUnrelatedTrace(trace, kind) {
  let text;
  try { text = await readFile(trace, "utf8"); }
  catch (e) { if (e.code === "ENOENT") return; throw e; }
  let previous;
  try { previous = JSON.parse(text); } catch { /* Existing source or other data. */ }
  if (previous?.kind !== kind || previous.version !== 1) {
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

export async function buildTaskGroupLowering({ compiler, input, output, entry, jobs, root, artifacts, runner, phase = "lowering" }) {
  if (!["lowering", "functions"].includes(phase)) throw new Error("unknown TaskGroup compiler phase");
  const kind = `vibe-taskgroup-${phase}`;
  const traceSetting = process.env[phase === "functions" ? "VIBE_FUNCTION_TRACE_OUT" : "VIBE_LOWERING_TRACE_OUT"];
  if (![1, 2, 4].includes(jobs)) throw new Error("lowering jobs must be 1, 2 or 4");
  root = resolve(root); artifacts = resolve(artifacts); runner = resolve(runner);
  const destination = resolve(root, output);
  const trace = traceSetting ? resolve(root, traceSetting) : null;
  if (trace) {
    await refuseTraceAlias(trace, destination);
    await refuseTraceAlias(trace, resolve(root, input), "source entry");
    await refuseUnrelatedTrace(trace, kind);
    await rm(trace, { force: true });
  }
  const digest = async p => createHash("sha256").update(await readFile(p)).digest("hex");
  const receipt = JSON.parse(await readFile(join(artifacts, "build.json"), "utf8"));
  if ((receipt.kind ?? "vibe-taskgroup-lowering") !== kind || receipt.version !== 1 || receipt.compiler_sha256 !== await digest(resolve(compiler)) ||
      receipt.runner_sha256 !== await digest(runner)) throw new Error("rebuild lowering images for this compiler and runner");
  if (phase === "functions" && (receipt.function_abi !== "bump-core-tagged-callbacks-1" ||
      receipt.context_format !== 6 || receipt.job_format !== 2 || receipt.compile_engine_rc !== 0 || receipt.worker_engine_rc !== 0 || receipt.coordinator_engine_rc !== 1)) {
    throw new Error("rebuild function images for the supported native callback ABI");
  }
  for (const name of ["worker.wasm", "compile.wasm", "coordinator.component.wasm"]) {
    if (receipt.artifacts[name] !== await digest(join(artifacts, name))) throw new Error(`lowering image changed: ${name}`);
  }
  const work = await mkdtemp(join(tmpdir(), "vibe-lowering-")), started = performance.now();
  const base = { VIBE_LOWERING_INPUT: input, VIBE_LOWERING_ENTRY: entry,
    VIBE_LOWERING_DIRECTORY: work, VIBE_FUNCTION_JOBS: String(jobs), VIBE_PREOPEN_DIR: root, VIBE_IMPORT_ABI: "raw" };
  if (phase === "functions") base.VIBE_RC = "1";
  try {
    const privateOutput = join(work, "result.wasm");
    const service = join(work, "service.json");
    await writeFile(service, JSON.stringify({ version: 1,
      worker: join(artifacts, "worker.wasm"), coordinator: join(artifacts, "coordinator.component.wasm"),
      runner, cwd: root, directory: work, jobs }));
    await run(runner, join(artifacts, "compile.wasm"), root, { ...base,
      VIBE_LOWERING_MODE: "single", VIBE_LOWERING_OUTPUT: privateOutput,
      VIBE_LOWERING_SERVICE_CONFIG: service });
    const serviceReport = JSON.parse(await readFile(join(work, "service-report.json"), "utf8"));
    if (serviceReport.preparation_count !== 1 || serviceReport.modules <= 0 || serviceReport.workers !== jobs) {
      throw new Error("lowering returned an incomplete native service report");
    }
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
    const outputStaging = await mkdtemp(join(dirname(destination), ".vibe-lowering-output-"));
    const staging = join(outputStaging, "result.wasm");
    let traceWritten = false, published = false, traceStaging = null;
    try {
      await writeFile(staging, result, { flag: "wx" });
      const finished = performance.now();
      let phaseReport = serviceReport;
      if (phase === "functions") {
        const plan = JSON.parse(await readFile(join(work, "function-plan.json"), "utf8"));
        if (!Number.isSafeInteger(plan.functions) || plan.functions <= 0 || !Number.isSafeInteger(plan.lambdas) || plan.lambdas < 0) {
          throw new Error("functions: invalid plan report");
        }
        const { modules: rangeJobs, ...timings } = serviceReport;
        delete timings.replay_ms;
        phaseReport = { ...timings, range_jobs: rangeJobs, ...plan,
          phase_scope: "prepare: whole-program lowering and canonical function planning; worker: context encoding, isolated TaskGroup CPU processes, product decoding and validation; finalize: canonical replay, module assembly, source verification and private output write" };
      }
      const report = { ...phaseReport, version: 1, kind,
        total_ms: finished - started };
      if (trace) {
        await refuseTraceAlias(trace, destination);
        await refuseTraceAlias(trace, resolve(root, input), "source entry");
        await refuseUnrelatedTrace(trace, kind);
        traceStaging = await mkdtemp(join(dirname(trace), ".vibe-lowering-trace-"));
        const stagedReport = join(traceStaging, "report.json");
        await writeFile(stagedReport, JSON.stringify(report), { flag: "wx" });
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
      await rm(outputStaging, { recursive: true, force: true });
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
