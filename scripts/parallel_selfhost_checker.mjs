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
      VIBE_CHECK_ONLY: "1",
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

  async check(module) {
    await this.start();
    const stem = fingerprint(module.id).slice(0, 16);
    const sourcePath = `${stem}.vibe`;
    const outputPath = `${stem}.checked`;
    const diagnosticPath = `${outputPath}.diag`;
    const sourceFile = join(this.workRoot, sourcePath);
    const outputFile = join(this.workRoot, outputPath);
    const diagnosticFile = join(this.workRoot, diagnosticPath);
    await writeFile(sourceFile, module.source, "utf8");
    await rm(outputFile, { force: true });
    await rm(diagnosticFile, { force: true });

    const response = await this.request([sourcePath, outputPath, "__no_entry__"]);
    let diagnostic = "";
    let marker = "";
    try {
      marker = (await readFile(outputFile, "utf8")).trim();
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    try {
      diagnostic = (await readFile(diagnosticFile, "utf8")).trim();
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await rm(sourceFile, { force: true });
    await rm(outputFile, { force: true });
    await rm(diagnosticFile, { force: true });

    if (response.exit_code === 0 && marker === "ok" && diagnostic.length === 0) {
      return null;
    }
    if (response.exit_code === 0) {
      throw new Error(
        `selfhost checker returned success without its canonical ok marker (marker=${JSON.stringify(marker)}, diagnostic=${JSON.stringify(diagnostic)})`,
      );
    }
    if (diagnostic.length === 0) {
      throw new Error(
        response.error ??
          `selfhost checker exited ${response.exit_code} without a diagnostic`,
      );
    }
    return {
      module: module.id,
      start: 0,
      end: module.source.length,
      code: "E_SELFHOST_CHECK",
      message: diagnostic,
    };
  }
}
