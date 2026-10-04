// Public build host action. Vibe parses the request and owns CPU task lifetime.
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { warmTaskGroupProject } from "./taskgroup_frontend_warm.mjs";

const request = process.argv.slice(2), verifyOnly = request[0] === "--verify";
const [compiler, entryFile, count, root, artifacts, runner] = verifyOnly
  ? [request[1], null, null, null, request[2], null] : request;
try {
  if (verifyOnly ? !compiler || !artifacts || request.length !== 3
    : ![compiler, entryFile, count, root, artifacts, runner].every(Boolean)) {
    throw new Error("usage: taskgroup_build_frontend.mjs <compiler> <entry> <jobs> <root> <artifacts> <native-runner>");
  }
  const compilerWasm = resolve(compiler), artifactRoot = resolve(artifacts);
  const receipt = JSON.parse(await readFile(join(artifactRoot, "build.json"), "utf8"));
  const digest = async path => createHash("sha256").update(await readFile(path)).digest("hex");
  if (await digest(compilerWasm) !== receipt.compiler_sha256) {
    throw new Error("TaskGroup images belong to a different compiler; rebuild them with scripts/build_taskgroup_checker.sh");
  }
  for (const name of ["worker.wasm", "coordinator.component.wasm"]) {
    const matches = Object.entries(receipt.artifacts).filter(([path]) => basename(path) === name);
    if (matches.length !== 1 || await digest(join(artifactRoot, name)) !== matches[0][1]) {
      throw new Error(`TaskGroup image does not match its build receipt: ${name}`);
    }
  }
  if (!verifyOnly) {
    await warmTaskGroupProject({ compilerWasm, entryFile, jobs: Number(count), projectRoot: root,
      runnerPath: resolve(runner), nativeRunner: resolve(runner), nativeCompiler: true,
      workerWasm: join(artifactRoot, "worker.wasm"),
      coordinatorWasm: join(artifactRoot, "coordinator.component.wasm") });
  }
} catch (error) {
  console.error(`build --jobs: ${error.message}`);
  process.exitCode = 1;
}
