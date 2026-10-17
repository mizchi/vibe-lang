import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { buildTaskGroupLowering } from "./taskgroup_lowering_frontend.mjs";

export async function buildTaskGroupFunctions(options) {
  if (process.env.VIBE_UNSTABLE !== "1") throw new Error("functions require VIBE_UNSTABLE=1");
  if (![undefined, "", "1"].includes(process.env.VIBE_RC)) throw new Error("functions require VIBE_RC=1");
  if (![undefined, "", "linear"].includes(process.env.VIBE_BACKEND)) throw new Error("functions require the linear backend");
  if (![undefined, "", "off"].includes(process.env.VIBE_CODEGEN_BODY_CACHE)) throw new Error("functions require VIBE_CODEGEN_BODY_CACHE=off");
  for (const name of ["VIBE_COVERAGE", "VIBE_DEBUG", "VIBE_DEBUG_BREAK", "VIBE_TASKGROUP_LOWERING"]) {
    if (process.env[name] && process.env[name] !== "0") throw new Error(`functions do not support ${name}`);
  }
  return buildTaskGroupLowering({ ...options, phase: "functions" });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [compiler, input, output, entry, count, root, artifacts, runner] = process.argv.slice(2);
  buildTaskGroupFunctions({ compiler, input, output, entry, jobs: Number(count), root, artifacts, runner })
    .catch(e => { console.error(`build --jobs functions: ${e.message}`); process.exitCode = 1; });
}
