import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";

import { join } from "node:path";
import { createInterface } from "node:readline";

function fingerprint(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

export class SelfhostChecker {
  constructor(execution, workRoot, notifyRuntime) {
    this.execution = execution;
    this.workRoot = workRoot;
    this.notifyRuntime = notifyRuntime;
    this.child = null;
    this.pending = [];
    this.stderr = "";
    this.closed = false;
  }

  async start() {
    if (this.child !== null) return;
    await mkdir(this.workRoot, { recursive: true });
    const env = { ...process.env };
    for (const name of [
      "VIBE_FS_COMPILE",
      "VIBE_DIAGNOSTICS",
      "VIBE_TYPE_AT",
      "VIBE_BINDING_AT",
      "VIBE_SYMBOLS",
      "VIBE_NORMALIZE",
      "VIBE_COVERAGE",
      "VIBE_DEBUG",
      "VIBE_DEBUG_BREAK",
      "VIBE_EMIT_MODULE_SOURCE",
    ]) {
      delete env[name];
    }
    Object.assign(env, {
      VIBE_PREOPEN_DIR: this.workRoot,
      // #906 Phase 2: job-dir mode, not VIBE_CHECK_ONLY. Check-only resolves
      // a module's imports off the real filesystem, which is exactly what a
      // worker must not do -- and it is why this bridge could previously
      // only handle leaf snapshots. In job-dir mode the dependency
      // environments arrive as values the coordinator supplies.
      VIBE_MODULE_JOB_DIR: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE: "1",
    });
    const child = spawn(
      "bash",
      [
        this.execution.runnerPath,
        "--daemon",
        "--invoke",
        "cli_main",
        this.execution.compilerWasm,
      ],
      {
        cwd: this.workRoot,
        env,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    this.child = child;
    this.notifyRuntime({ type: "runtimeStarted", pid: child.pid });

    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => {
      const request = this.pending.shift();
      if (!request) return;
      try {
        request.resolve(JSON.parse(line));
      } catch (error) {
        request.reject(
          new Error(`invalid selfhost daemon response: ${line}: ${error.message}`),
        );
      }
    });
    child.stderr.on("data", (chunk) => {
      this.stderr = `${this.stderr}${chunk}`.slice(-4096);
    });
    child.on("error", (error) => this.rejectPending(error));
    child.on("close", (code, signal) => {
      this.notifyRuntime({ type: "runtimeStopped", pid: child.pid });
      this.rejectPending(
        new Error(
          `selfhost daemon stopped (code=${code ?? "null"}, signal=${signal ?? "null"})${
            this.stderr.length === 0 ? "" : `: ${this.stderr.trim()}`
          }`,
        ),
      );
      this.closed = true;
    });
  }

  rejectPending(error) {
    for (const request of this.pending.splice(0)) request.reject(error);
  }

  async request(args) {
    await this.start();
    if (this.closed || this.child === null) {
      throw new Error("selfhost daemon is not running");
    }
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.child.stdin.write(`${JSON.stringify({ args })}\n`, (error) => {
        if (!error) return;
        const request = this.pending.pop();
        request?.reject(error);
      });
    });
  }

  async readIfPresent(path) {
    try {
      return await readFile(path, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  }

  // Check one module inside a job directory. `dependencies` are the
  // coordinator's terminal outcomes for this module's direct dependencies,
  // IN DECLARATION ORDER -- dep<i>.env is positional, so reordering them
  // would silently bind imports to the wrong environments.
  //
  // Returns { diagnostic, env }: `env` is the module's serialized public
  // environment, which the coordinator hands to this module's dependents.
  // That is the whole point of the job dir -- a worker cannot look a
  // dependency up in the type-env cache, because the key derives from the
  // transitive source snapshot it is not allowed to see.
  async check(module, dependencies = []) {
    await this.start();
    const stem = fingerprint(module.id).slice(0, 16);
    const jobName = `job-${stem}`;
    const jobDir = join(this.workRoot, jobName);
    await rm(jobDir, { recursive: true, force: true });
    await mkdir(jobDir, { recursive: true });

    const rows = ["version\t1", `path\t${module.id}`, `fingerprint\t${stem}`];
    for (const dependency of dependencies) rows.push(`dep\t${dependency.id}`);
    await writeFile(join(jobDir, "job.txt"), `${rows.join("\n")}\n`, "utf8");
    await writeFile(join(jobDir, "source.vibe"), module.source, "utf8");
    for (const [index, dependency] of dependencies.entries()) {
      const env = dependency.outcome?.artifact?.env;
      if (typeof env !== "string" || env.length === 0) continue;
      await writeFile(join(jobDir, `dep${index}.env`), env, "utf8");
    }

    const response = await this.request([jobName, `${jobName}/worker.out`, "__no_entry__"]);
    const outcome = (await this.readIfPresent(join(jobDir, "outcome.txt")))?.trim() ?? "";
    const diagnostic = (await this.readIfPresent(join(jobDir, "diag.txt")))?.trim() ?? "";
    const env = await this.readIfPresent(join(jobDir, "env.out"));
    const workerDiag = (
      await this.readIfPresent(join(jobDir, "worker.out.diag"))
    )?.trim();
    await rm(jobDir, { recursive: true, force: true });

    // A missing outcome.txt is an infrastructure failure, never a
    // diagnostic: the worker writes it last precisely so its absence means
    // "this did not finish", not "this module is fine".
    if (outcome.length === 0) {
      throw new Error(
        workerDiag ??
          response.error ??
          `selfhost worker exited ${response.exit_code} without writing an outcome`,
      );
    }
    if (outcome === "ok") {
      if (response.exit_code !== 0) {
        throw new Error(
          `selfhost worker reported ok but exited ${response.exit_code}`,
        );
      }
      // An "ok" with no usable environment must NOT be published as a
      // checked outcome. Dependents skip writing dep<i>.env for an empty
      // env, which makes their imports lenient again -- so a truncated or
      // missing env.out would quietly turn real type errors in every
      // dependent into a clean check. Even an empty environment
      // serializes a version header, so "nonempty" is the right bar, and
      // failing the run is the right response to a malformed worker
      // answer.
      if (typeof env !== "string" || env.trim().length === 0) {
        throw new Error(
          `selfhost worker reported ok for "${module.id}" without a usable env.out`,
        );
      }
      return { diagnostic: null, env };
    }
    if (outcome !== "diag") {
      throw new Error(`unknown module job outcome: ${JSON.stringify(outcome)}`);
    }
    if (diagnostic.length === 0) {
      throw new Error("selfhost worker reported a diagnostic outcome with no diagnostic");
    }
    return {
      diagnostic: {
        module: module.id,
        start: 0,
        end: module.source.length,
        code: "E_SELFHOST_CHECK",
        message: diagnostic,
      },
      env: "",
    };
  }
}
