function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

function deepFreeze(value) {
  if (value === null || typeof value !== "object" || Object.isFrozen(value)) {
    return value;
  }
  Object.freeze(value);
  for (const nested of Object.values(value)) deepFreeze(nested);
  return value;
}

export function normalizeParallelProject(project) {
  invariant(Array.isArray(project), "project must be an array");
  const modules = new Map();
  for (const candidate of project) {
    invariant(candidate && typeof candidate === "object", "module must be an object");
    invariant(
      typeof candidate.id === "string" && candidate.id.length > 0,
      "module id must be a non-empty string",
    );
    invariant(!modules.has(candidate.id), `duplicate module id: "${candidate.id}"`);
    invariant(
      Array.isArray(candidate.dependencies),
      `dependencies for "${candidate.id}" must be an array`,
    );
    invariant(
      typeof candidate.source === "string",
      `source for "${candidate.id}" must be a string`,
    );
    const workMs = candidate.workMs ?? 0;
    invariant(
      Number.isInteger(workMs) && workMs >= 0,
      `workMs for "${candidate.id}" must be a non-negative integer`,
    );
    modules.set(
      candidate.id,
      deepFreeze({
        id: candidate.id,
        dependencies: [...candidate.dependencies],
        source: candidate.source,
        workMs,
        crash: candidate.crash === true,
      }),
    );
  }

  for (const module of modules.values()) {
    const seen = new Set();
    for (const dependency of module.dependencies) {
      invariant(
        typeof dependency === "string" && modules.has(dependency),
        `unknown dependency "${dependency}" of "${module.id}"`,
      );
      invariant(dependency !== module.id, `self dependency: "${module.id}"`);
      invariant(
        !seen.has(dependency),
        `duplicate dependency "${dependency}" of "${module.id}"`,
      );
      seen.add(dependency);
    }
  }

  const visiting = new Set();
  const visited = new Set();
  const visit = (id) => {
    if (visited.has(id)) return;
    invariant(!visiting.has(id), `dependency cycle reaches "${id}"`);
    visiting.add(id);
    for (const dependency of modules.get(id).dependencies) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  };
  for (const id of [...modules.keys()].sort()) visit(id);

  return modules;
}

export function validateParallelTrace(project, trace, jobs) {
  invariant(
    Number.isInteger(jobs) && jobs >= 1,
    "jobs must be an integer greater than or equal to 1",
  );
  invariant(Array.isArray(trace), "trace must be an array");
  const modules = normalizeParallelProject(project);
  const ids = [...modules.keys()].sort();
  const phases = new Map(ids.map((id) => [id, "pending"]));
  const workers = new Map(Array.from({ length: jobs }, (_, worker) => [worker, null]));
  const published = new Set();
  const committed = [];
  const projectedAsyncEvents = [];
  let running = 0;
  let maxRunning = 0;

  for (const [index, event] of trace.entries()) {
    invariant(event.seq === index, `trace sequence mismatch at index ${index}`);
    invariant(modules.has(event.task), `unknown trace task "${event.task}"`);
    const phase = phases.get(event.task);
    if (event.kind === "ready") {
      invariant(phase === "pending", `task "${event.task}" is not pending`);
      for (const dependency of modules.get(event.task).dependencies) {
        invariant(
          published.has(dependency),
          `task "${event.task}" became ready before "${dependency}" was terminal`,
        );
      }
      phases.set(event.task, "ready");
    } else if (event.kind === "claim") {
      invariant(workers.has(event.worker), `unknown worker ${event.worker}`);
      invariant(phase === "ready", `task "${event.task}" is not ready`);
      invariant(workers.get(event.worker) === null, `worker ${event.worker} is not idle`);
      invariant(
        ![...workers.values()].includes(event.task),
        `task "${event.task}" already has a worker`,
      );
      workers.set(event.worker, event.task);
      phases.set(event.task, "running");
      running += 1;
      maxRunning = Math.max(maxRunning, running);
      projectedAsyncEvents.push({ kind: "dispatch", task: event.task });
    } else if (event.kind === "releaseComplete") {
      invariant(workers.has(event.worker), `unknown worker ${event.worker}`);
      invariant(phase === "running", `task "${event.task}" is not running`);
      invariant(
        workers.get(event.worker) === event.task,
        `worker ${event.worker} does not own task "${event.task}"`,
      );
      workers.set(event.worker, null);
      phases.set(event.task, "completed");
      running -= 1;
      projectedAsyncEvents.push({
        kind: "complete",
        task: event.task,
        outcome: "succeeded",
      });
    } else if (event.kind === "publish") {
      invariant(phase === "completed", `task "${event.task}" is not completed`);
      invariant(!published.has(event.task), `task "${event.task}" was already published`);
      phases.set(event.task, "terminal");
      published.add(event.task);
    } else if (event.kind === "commit") {
      invariant(
        published.size === ids.length,
        `task "${event.task}" committed before all outcomes were terminal`,
      );
      const expected = ids[committed.length];
      invariant(
        event.task === expected,
        `non-canonical commit order: expected "${expected}", got "${event.task}"`,
      );
      committed.push(event.task);
    } else {
      throw new Error(`unknown trace event kind: "${event.kind}"`);
    }
  }

  const complete =
    ids.every((id) => phases.get(id) === "terminal") &&
    committed.length === ids.length &&
    [...workers.values()].every((task) => task === null);
  invariant(complete, "trace ended before every task was terminal and committed");
  return { complete, maxRunning, projectedAsyncEvents };
}
