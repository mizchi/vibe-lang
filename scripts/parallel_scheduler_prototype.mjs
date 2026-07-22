import { Worker } from "node:worker_threads";
import { access, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  normalizeParallelProject,
  validateParallelTrace,
} from "./parallel_scheduler_trace.mjs";

function compareStrings(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function canonicalOutput(ids, outcomes) {
  const artifacts = [];
  const diagnostics = [];
  for (const id of ids) {
    const outcome = outcomes.get(id);
    if (outcome.kind === "checked") artifacts.push(outcome.artifact);
    else diagnostics.push(...outcome.diagnostics);
  }
  diagnostics.sort(
    (left, right) =>
      compareStrings(left.module, right.module) ||
      left.start - right.start ||
      left.end - right.end ||
      compareStrings(left.code, right.code) ||
      compareStrings(left.message, right.message),
  );
  return JSON.stringify({ artifacts, diagnostics });
}

async function normalizeExecution(execution) {
  const candidate = execution ?? { kind: "synthetic" };
  if (candidate.kind === "synthetic") return { kind: "synthetic" };
  if (candidate.kind !== "selfhost-check") {
    throw new Error(`unknown parallel execution kind: "${candidate.kind}"`);
  }
  if (
    typeof candidate.compilerWasm !== "string" ||
    candidate.compilerWasm.length === 0
  ) {
    throw new Error("selfhost-check requires compilerWasm");
  }
  const compilerWasm = resolve(candidate.compilerWasm);
  await access(compilerWasm);
  const runnerPath = resolve(
    candidate.runnerPath ??
      join(dirname(fileURLToPath(import.meta.url)), "run_wasm_vibe_host_runner.sh"),
  );
  await access(runnerPath);
  return { kind: "selfhost-check", compilerWasm, runnerPath };
}

function coordinatorRun(modules, jobs, workers, runtimeProcesses) {
  const ids = [...modules.keys()].sort();
  const phases = new Map(ids.map((id) => [id, "pending"]));
  const outcomes = new Map();
  const slots = workers.map((worker, id) => ({ id, worker, task: null }));
  const trace = [];
  let settled = false;

  const emit = (event) => trace.push({ seq: trace.length, ...event });
  const fail = (reject, error) => {
    if (settled) return;
    settled = true;
    reject(error);
  };

  return new Promise((resolve, reject) => {
    const finishIfComplete = () => {
      if (settled || outcomes.size !== ids.length) return false;
      for (const id of ids) emit({ kind: "commit", task: id });
      validateParallelTrace([...modules.values()], trace, jobs);
      settled = true;
      resolve({ output: canonicalOutput(ids, outcomes), outcomes, trace });
      return true;
    };

    const markReady = () => {
      for (const id of ids) {
        if (phases.get(id) !== "pending") continue;
        const module = modules.get(id);
        if (module.dependencies.every((dependency) => phases.get(dependency) === "terminal")) {
          phases.set(id, "ready");
          emit({ kind: "ready", task: id });
        }
      }
    };

    const dispatch = () => {
      if (settled || finishIfComplete()) return;
      markReady();
      const ready = ids.filter((id) => phases.get(id) === "ready");
      for (const slot of slots) {
        if (slot.task !== null || ready.length === 0) continue;
        const task = ready.shift();
        const module = modules.get(task);
        const dependencySnapshot = module.dependencies.map((dependency) => ({
          id: dependency,
          outcome: outcomes.get(dependency),
        }));
        phases.set(task, "running");
        slot.task = task;
        emit({ kind: "claim", worker: slot.id, task });
        slot.worker.postMessage({
          type: "run",
          job: { module, dependencies: dependencySnapshot },
        });
      }
    };

    for (const slot of slots) {
      slot.worker.on("message", (message) => {
        if (message.type === "runtimeStarted") {
          runtimeProcesses.add(message.pid);
          return;
        }
        if (message.type === "runtimeStopped") {
          runtimeProcesses.delete(message.pid);
          return;
        }
        if (settled) return;
        if (message.type === "failure") {
          fail(
            reject,
            new Error(`worker task "${message.task}" failed: ${message.message}`),
          );
          return;
        }
        if (message.type !== "result") return;
        if (slot.task !== message.task) {
          fail(
            reject,
            new Error(
              `worker ${slot.id} returned task "${message.task}" while owning "${slot.task}"`,
            ),
          );
          return;
        }
        emit({ kind: "releaseComplete", worker: slot.id, task: message.task });
        phases.set(message.task, "completed");
        slot.task = null;
        outcomes.set(message.task, message.outcome);
        phases.set(message.task, "terminal");
        emit({ kind: "publish", task: message.task });
        dispatch();
      });
      slot.worker.on("error", (error) => {
        const task = slot.task ?? "<idle>";
        fail(reject, new Error(`worker task "${task}" failed: ${error.message}`));
      });
      slot.worker.on("exit", (code) => {
        if (!settled && code !== 0) {
          const task = slot.task ?? "<idle>";
          fail(reject, new Error(`worker task "${task}" failed: exited with ${code}`));
        }
      });
    }

    dispatch();
  });
}

export async function runParallelProject(project, options = {}) {
  const jobs = options.jobs ?? 1;
  if (!Number.isInteger(jobs) || jobs < 1) {
    throw new Error("jobs must be an integer greater than or equal to 1");
  }
  const modules = normalizeParallelProject(project);
  if (modules.size === 0) {
    return {
      output: JSON.stringify({ artifacts: [], diagnostics: [] }),
      outcomes: new Map(),
      trace: [],
    };
  }

  const execution = await normalizeExecution(options.execution);
  const runtimeRoot =
    execution.kind === "selfhost-check"
      ? await mkdtemp(join(tmpdir(), "vibe-parallel-check-"))
      : null;
  const runtimeProcesses = new Set();

  const workers = Array.from(
    { length: Math.min(jobs, modules.size) },
    (_, worker) =>
      new Worker(new URL("./parallel_scheduler_worker.mjs", import.meta.url), {
        workerData: {
          execution,
          workRoot:
            runtimeRoot === null ? null : join(runtimeRoot, `worker-${worker}`),
        },
      }),
  );
  try {
    return await coordinatorRun(modules, jobs, workers, runtimeProcesses);
  } finally {
    try {
      for (const pid of runtimeProcesses) {
        try {
          process.kill(pid, "SIGTERM");
        } catch (error) {
          if (error?.code !== "ESRCH") throw error;
        }
      }
    } finally {
      await Promise.all(workers.map((worker) => worker.terminate()));
      if (runtimeRoot !== null) {
        await rm(runtimeRoot, { recursive: true, force: true });
      }
    }
  }
}

export { validateParallelTrace };
