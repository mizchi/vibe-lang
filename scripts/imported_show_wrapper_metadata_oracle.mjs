// Real FS rendering and checked-module reuse, including a same-signature body
// edit. Every invocation is a fresh compiler process; cache hits are observed
// through compiler telemetry rather than inferred from matching output.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseIncrementalTelemetry } from "./edit_cycle_kpi.mjs";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const compiler = resolve(process.argv[2] || process.env.VIBE_STAGE2_WASM || "");
assert(existsSync(compiler), "pass a freshly built compiler Wasm");
const work = mkdtempSync(join(repo, "_build/imported-show-metadata-"));
const project = join(work, "project");
mkdirSync(project);
const cache = join(work, "cache");
mkdirSync(cache);
const runner = process.env.VIBE_SHOW_METADATA_ORACLE_RUNNER || join(repo, "scripts/run_wasm_vibe_host_runner.sh");
const base = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("VIBE_")));
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const source = (name, text) => writeFileSync(join(project, name), text);
const samples = [];

source("leaf.vibe", `export fn render[T](value: T) -> String { __to_string(value) }
export fn mono(value: Bool) -> String { __to_string(value) }
export fn Qualified::render[T](value: T) -> String { __to_string(value) }
export fn ordinary(value: Bool) -> Bool { value }
`);
source("middle.vibe", "export ./leaf.vibe { render as first, mono, ordinary }\n");
source("facade.vibe", "export ./middle.vibe { first as last, mono, ordinary }\n");
const app = `import @vibe/builtin { to_string }
import ./leaf.vibe { Qualified::render as qualified_show }
import ./facade.vibe { last as show, mono, ordinary as show_ordinary }
fn main() -> Int allows Console {
  let b = () -> Bool { 1 < 2 }
  let d = () -> Double { 2.5 }
  let c = () -> Char { Char::from_int(113) }
  let u = () -> Unit { () }
  let a = () -> Array[Bool] { [1 < 2, 2 < 1] }
  let o = () -> Option[Char] { Some(Char::from_int(122)) }
  let t = () -> (Double, Bool, Unit) { (2.5, 1 < 2, ()) }
  assert(show(b()) == "true")
  assert(to_string(b()) == "true")
  assert(to_string(c()) == "q")
  assert(qualified_show(b()) == "true")
  assert(show(d()) == "2.5")
  assert(show(c()) == "q")
  assert(show(u()) == "()")
  assert(show(a()) == "[true, false]")
  assert(show(o()) == "Some(z)")
  assert(show(t()) == "(2.5, true, ())")
  println(mono(b()))
  assert(show_ordinary(b()))
  0
}
`;
source("app.vibe", app);

function compile(label, mode = "on", expectedMono = "true") {
  const output = join(work, `${label}.wasm`);
  const telemetry = join(work, `${label}.telemetry.json`);
  rmSync(`${output}.diag`, { force: true });
  const env = { ...base, VIBE_PREOPEN_DIR: project, VIBE_LIB: join(repo, "lib"),
    VIBE_FS_COMPILE: "1", VIBE_IMPORT_ABI: "raw", VIBE_RC: "1",
    VIBE_CHECKED_MODULE_CACHE: mode, VIBE_CODEGEN_BODY_CACHE: "off",
    VIBE_EXPERIMENTAL_AST_CACHE: "0", VIBE_BUILD_CACHE_DIR: cache,
    VIBE_INCREMENTAL_TELEMETRY_OUT: telemetry };
  const result = spawnSync("bash", [runner, "--invoke", "cli_main", compiler,
    "app.vibe", output, "main"], { cwd: project, env, encoding: "utf8", timeout: 180_000 });
  writeFileSync(join(work, `${label}.compile.log`), result.stdout + result.stderr);
  assert.equal(result.status, 0, existsSync(`${output}.diag`) ? readFileSync(`${output}.diag`, "utf8") : result.stderr);
  assert(existsSync(output), "compile succeeded without Wasm");
  const run = spawnSync("bash", [runner, "--invoke", "main", output], {
    cwd: project, env: { ...base, VIBE_IMPORT_ABI: "raw", VIBE_PREOPEN_DIR: project,
      VIBE_RUNNER_EXIT_WITH_RESULT: "1" }, encoding: "utf8", timeout: 30_000 });
  writeFileSync(join(work, `${label}.run.log`), run.stdout + run.stderr);
  assert.equal(run.status, 0, `compiled render assertions failed: ${run.stderr}`);
  assert.equal(run.stdout.trim(), `${expectedMono}\n0`, "compiled render result");
  const counters = parseIncrementalTelemetry(readFileSync(telemetry, "utf8"), telemetry);
  const sample = { label, mode, output_sha256: hash(readFileSync(output)), counters };
  samples.push(sample);
  console.log(label, sample.output_sha256, `checked hits=${counters.modules_reused_checked_module_artifact || 0}`);
  return sample;
}

const cold = compile("cold");
assert.equal(cold.counters.modules_reused_checked_module_artifact, 0);
const warm = compile("warm");
assert(warm.counters.modules_reused_checked_module_artifact > 0, "warm compile did not reuse checked modules");
assert.equal(warm.output_sha256, cold.output_sha256);
const verified = compile("verified", "verify");
assert.equal(verified.output_sha256, cold.output_sha256);

// The dependency signature stays Bool -> String. The body stops being a
// wrapper, and stale render facts/artifacts must not survive that edit.
source("leaf.vibe", `export fn render[T](value: T) -> String { __to_string(value) }
export fn mono(value: Bool) -> String { "plain" }
export fn Qualified::render[T](value: T) -> String { __to_string(value) }
export fn ordinary(value: Bool) -> Bool { value }
`);
assert.equal(readFileSync(join(project, "app.vibe"), "utf8"), app);
const edited = compile("body-edit", "on", "plain");
assert.notEqual(edited.output_sha256, cold.output_sha256);
assert(edited.counters.checker_executions > 0, "body edit did not check affected input");
const editedWarm = compile("body-edit-warm", "on", "plain");
assert(editedWarm.counters.modules_reused_checked_module_artifact > 0);
assert.equal(editedWarm.output_sha256, edited.output_sha256);
writeFileSync(join(work, "results.json"), JSON.stringify({ status: "passed", compiler,
  compiler_sha256: hash(readFileSync(compiler)), samples }, null, 2) + "\n");
console.log(`imported Show metadata oracle passed: ${work}`);
