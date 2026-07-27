import { createHash } from "node:crypto";
import { parentPort, workerData } from "node:worker_threads";

import { SelfhostChecker } from "./parallel_selfhost_checker.mjs";

function fingerprint(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

function diagnosticFromSource(module) {
  const prefix = "diagnostic:";
  if (!module.source.startsWith(prefix)) return null;
  const rest = module.source.slice(prefix.length);
  const separator = rest.indexOf(":");
  const code = separator < 0 ? "E_PROTOTYPE" : rest.slice(0, separator);
  const message = separator < 0 ? rest : rest.slice(separator + 1);
  return {
    module: module.id,
    start: 0,
    end: module.source.length,
    code,
    message,
  };
}

const selfhostChecker =
  workerData.execution.kind === "selfhost-check"
    ? new SelfhostChecker(
        workerData.execution,
        workerData.workRoot,
        (message) => parentPort.postMessage(message),
      )
    : null;

async function compile(job) {
  if (job.module.workMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, job.module.workMs));
  }
  if (job.module.crash) throw new Error("prototype worker crash");

  const failedDependencies = job.dependencies
    .filter((dependency) => dependency.outcome.kind === "diagnosed")
    .map((dependency) => dependency.id)
    .sort();
  if (failedDependencies.length > 0) {
    return {
      kind: "diagnosed",
      diagnostics: [
        {
          module: job.module.id,
          start: 0,
          end: 0,
          code: "E_DEPENDENCY",
          message: `dependency diagnostics: ${failedDependencies.join(", ")}`,
        },
      ],
    };
  }

  // #906 Phase 2: the selfhost path returns the module's public environment
  // alongside its diagnostic, so the coordinator can hand it to dependents.
  // Without that a worker could only ever check leaf modules.
  const checked =
    selfhostChecker === null
      ? { diagnostic: diagnosticFromSource(job.module), env: "", fingerprint: null }
      : await selfhostChecker.check(job.module, job.dependencies);
  if (checked.diagnostic) {
    return { kind: "diagnosed", diagnostics: [checked.diagnostic] };
  }

  return {
    kind: "checked",
    artifact: {
      module: job.module.id,
      env: checked.env,
      // The selfhost checker returns the CANONICAL fingerprint --
      // check_module's own build_fingerprint(source, dep_fps), the same
      // value the serial compiler would derive for this module -- not a
      // value this script invents. The synthetic-hash fallback below only
      // applies to the `synthetic` execution kind (no real compiler, used
      // by the fast prototype-contract tests), where there is no
      // build_fingerprint to defer to and the hash only needs to be
      // deterministic in source + dependency outcomes, not canonical.
      fingerprint:
        checked.fingerprint ??
        fingerprint({
          checker: workerData.execution.kind,
          id: job.module.id,
          source: job.module.source,
          dependencies: job.dependencies.map((dependency) => ({
            id: dependency.id,
            outcome: dependency.outcome,
          })),
        }),
    },
  };
}

parentPort.on("message", async (message) => {
  if (message.type !== "run") return;
  try {
    const outcome = await compile(message.job);
    parentPort.postMessage({ type: "result", task: message.job.module.id, outcome });
  } catch (error) {
    parentPort.postMessage({
      type: "failure",
      task: message.job.module.id,
      message: error instanceof Error ? error.message : String(error),
    });
  }
});
