#!/usr/bin/env node
// #2728 / #3796: is TypeEnv reuse on the COMPILE lane right on the edit shapes
// where it actually hits, and does it refuse every record it cannot trust?
//
// The reuse key is a module's verbatim source plus each direct dependency's
// exact public env text. So editing the module under test changes its own key,
// and editing a dependency's interface changes every consumer's key: both MISS,
// are checked fresh, and an oracle built from them passes whether or not the
// reuse arm is right. The shape that HITS is a dependency-body edit that
// changes the program's meaning while leaving that dependency's public env text
// identical. The consumer's key is unchanged and the hit happens, and the
// question is whether the compile-only state the hit republishes (the typed
// lowering offsets of the consumer's `==` sites, #2391) is still right. The
// public env being equal is what makes the hit happen, and exactly why it
// cannot detect the problem. So each claim below is stated against a fresh
// compile with reuse off in a separate cache, never against the reuse lane's
// own earlier answer, and against the program's EXECUTED result, computed here
// from the fixture state rather than read off any compile.
//
// Every compared pair agrees on four things: the module bytes, the
// diagnostics (exit status, stdout, stderr and the `.diag` file), and the
// executed result, which must also equal the value this oracle derives for
// the fixture state. Equal declarations alone would not show the edit landed.
//
//   core      meaning edit (an exported body), private edit (a non-exported
//             helper's body) and capability edit (a non-exported helper that
//             starts performing an optional capability): each HITS every
//             consumer (or the rest is vacuous), changes the program (or the
//             edit proved nothing) and equals a fresh reuse-off compile. A
//             dependency-body error must give the fresh diagnostics, and the
//             next good edit recovers. Reuse off records no hit (control);
//             every record overwritten with garbage misses; an interface edit
//             misses.
//   records   from a snapshot of the cold cache, alias, witness and target
//             records are corrupted INDEPENDENTLY, once malformed and once
//             spliced from another valid binding (a stale but well-formed
//             record). Each must miss and compile to the fresh module. The
//             uncorrupted snapshot is the control: it must hit, or a miss
//             below would prove nothing about the corruption.
//   config    the same edit under a different build configuration: the
//             `#cfg` flag set, the checked-error-row mode and the resolution
//             authority are reuse authority and must miss; the backend is not
//             typing authority, so it may hit, and must still equal a fresh
//             compile under that backend.
//   grants    `--allow-*` / `--deny-*` reach only `vibe run`'s artifact. A
//             full-grant run then a `--deny-env` run after an edit, through
//             one reuse-on cache, must execute exactly like a fresh `--deny-env`
//             run. That lane publishes no transport records today, and the
//             oracle says so: when it starts to, this case needs hit evidence.
//
// The body cache and the checked-module cache are OFF in every build: either
// could replay a stale body and make the comparison pass for another reason.
// The emitted JSON keeps each build's source digests, configuration, artifact
// digest, executed result and telemetry, so a run is identified by its inputs.
import { cpSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { aliasText, bindingFiles, parseAlias, parseBinding, witnessText } from "./experimental_typing_env_reuse_oracle.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`compile-typing-env-reuse-oracle: ${message}`); };
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

// Every VIBE_* variable is DROPPED, not inherited (#2252). The adapter diverts
// off the FS-compile lane on any of a long list of selectors, and an inherited
// VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE or reuse opt-in would decide the
// very thing this oracle measures.
const cleanEnv = Object.fromEntries(
  Object.entries(process.env).filter(([key]) => !key.startsWith("VIBE_")),
);

// Overridable ONLY so this oracle's own self-test can drive it with scripted
// builds; unset on every real invocation.
const runnerScript = process.env.VIBE_COMPILE_TYPING_REUSE_ORACLE_RUNNER
  || join(root, "scripts/run_wasm_vibe_host_runner.sh");

// Overridable ONLY so the self-test can run one section against the real
// compiler without paying for the others. Every real invocation runs all of
// them, and a narrowed run says so on stderr and in its JSON.
const allSections = ["core", "records", "config", "grants"];
const sections = (process.env.VIBE_COMPILE_TYPING_REUSE_ORACLE_SECTIONS || allSections.join(","))
  .split(",").filter(Boolean);
for (const section of sections) {
  if (!allSections.includes(section)) fail(`unknown section ${section} (known: ${allSections.join(", ")})`);
}

// ---- the fixture -----------------------------------------------------------
//
// `dep` is imported by `mid` and `app`, and `mid` by `app`, so a dependency
// edit leaves two consumers to reuse. `mid` compares two unannotated arrays
// whose elements are both call results, so neither side gives the element
// type syntactically: that `==` resolves only through the typed-lowering row
// the checker records (#2391), which is the compile-only state a reuse hit
// republishes. The self-test strips those rows from the reused records and
// requires this oracle to fail. `app` compares a `derive(Eq)` struct declared
// in `dep`, and its result subtracts, so a swapped argument changes it.
//
// Every state keeps `dep`'s public env identical except `extra`: the private
// helpers `tdre_bias` / `tdre_probe` / `tdre_cfg` are not exported, and the
// exported signatures never change. `tdre_cfg` exists only under a `#cfg` flag,
// so every build names one.
const probeBodies = {
  pure: "8",
  perform: 'match perform? Env::get("TDRE_CAP") { Granted(_) => 50, NotGranted => 30, Errored(_) => 10 }',
};

function depSource(state) {
  return [
    `fn tdre_bias() -> Int { ${state.bias} }`,
    `fn tdre_probe() -> Int with Env::get? { ${probeBodies[state.probe]} }`,
    `export fn tdre_k() -> Int { ${state.k} }`,
    `export fn tdre_name() -> String { "${state.name}" }`,
    "export fn tdre_two() -> Int { 2 }",
    "export struct TdrePt { x: Int; y: Int } derive(Eq)",
    "export fn tdre_pt(n: Int) -> TdrePt { TdrePt::{ x: n, y: tdre_k() } }",
    "export fn tdre_shift(n: Int) -> Int { n * 10 - tdre_bias() }",
    "export fn tdre_cap() -> Int with Env::get? { tdre_probe() }",
    "#cfg(tdre_lo)",
    "fn tdre_cfg() -> Int { 1 }",
    "#cfg(tdre_hi)",
    "fn tdre_cfg() -> Int { 2 }",
    "export fn tdre_mode() -> Int { tdre_cfg() }",
    state.extra || "",
  ].join("\n");
}

const depImports = "import ./dep.vibe { TdrePt, tdre_k, tdre_pt, tdre_shift, tdre_cap, tdre_mode }";
const eqLine = "  let eq = if tdre_pt(n = 1) == TdrePt::{ x: 1, y: 2 } { 7 } else { 0 }";
const totalExpr = "tdre_mode() * 1000000 + tdre_mid(n = 10) * 100 + tdre_k() + eq - tdre_shift(n = 3) + tdre_cap() * 3";

function makeProject(project, state) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "dep.vibe"), depSource(state));
  writeFileSync(join(project, "mid.vibe"), [
    "import ./dep.vibe { tdre_k, tdre_name, tdre_two }",
    "export fn tdre_mid(n: Int) -> Int {",
    "  let xs = []",
    "  Array::push(xs, value = tdre_k())",
    "  let ys = []",
    "  Array::push(ys, value = tdre_two())",
    "  let same = if xs == ys { 1000 } else { 0 }",
    "  n + tdre_k() + String::length(tdre_name()) + same",
    "}",
  ].join("\n"));
  writeFileSync(join(project, "app.vibe"), [
    "import ./mid.vibe { tdre_mid }",
    depImports,
    "fn main() -> Int allows Env::get? {",
    eqLine,
    `  ${totalExpr}`,
    "}",
  ].join("\n"));
  // `vibe run`'s entry for the grants section: the same computation, printed.
  writeFileSync(join(project, "run.vibex"), [
    "import ./mid.vibe { tdre_mid }",
    depImports,
    "fn main() -> Unit allows Env::get? + Console {",
    eqLine,
    `  println("tdre=\\{${totalExpr}}")`,
    "}",
  ].join("\n"));
}

function setState(project, state) {
  writeFileSync(join(project, "dep.vibe"), depSource(state));
}

// What the fixture computes in `state`, derived from the fixture's own
// definitions: never read off a compile, so a compile that replays a stale
// answer cannot agree with it. `granted` is whether `Env::get?` is granted;
// the compile lane links no grants, so there it is false.
function expectedResult(state, { mode = 1, granted = false } = {}) {
  const k = state.k;
  const mid = 10 + k + Buffer.byteLength(state.name) + (k === 2 ? 1000 : 0);
  const eq = k === 2 ? 7 : 0;
  const shift = 3 * 10 - Number(state.bias);
  const cap = state.probe === "pure" ? 8 : granted ? 50 : 30;
  return mode * 1000000 + mid * 100 + k + eq - shift + cap * 3;
}

const S0 = { k: 1, name: "a", bias: "4", probe: "pure" };
const SA = { ...S0, k: 2, name: "bbb" }; // exported bodies
const SP = { ...SA, bias: "9" }; // a non-exported helper's body
const SC = { ...SP, probe: "perform" }; // a non-exported helper now performs `Env::get?`
const SD = { ...SC, bias: "tdre_missing_helper()" }; // a body error, same public env
const SR = { ...SC, k: 3, name: "cc", bias: "6" }; // the good edit after it
const SG = { ...SR, k: 4, name: "dddd" }; // after every record was overwritten
const SI = { ...SA, extra: "export fn tdre_extra() -> Int { 9 }" }; // the interface edit
const SK = { ...S0, k: 3, name: "cc" }; // the control's warm-up

// ---- builds ----------------------------------------------------------------

const telemetryKeys = [
  "modules_planned", "modules_rechecked", "modules_reused",
  "modules_reused_dependency_transport_env",
];

function telemetry(path) {
  const value = JSON.parse(readFileSync(path, "utf8"));
  for (const key of telemetryKeys) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`invalid ${key} in ${path}`);
  }
  return value;
}

const baseConfig = { VIBE_RC: "1", VIBE_CFG: "tdre_lo" };

function readText(path) {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function sourceIdentity(project) {
  return Object.fromEntries(["dep.vibe", "mid.vibe", "app.vibe", "run.vibex"]
    .map((file) => [file, sha256(readFileSync(join(project, file)))]));
}

// Diagnostics as the user sees them. Paths under the scratch tree differ
// between the reuse-on cache and the fresh one, so they are folded first.
function normalize(text, ctx) {
  return text.split(ctx.work).join("<work>").replace(/\r\n/g, "\n").trim();
}

function build(ctx, name, { cache, reuse, config = {}, allowFailure = false }) {
  const project = ctx.project;
  const out = `${name}.wasm`;
  const telemetryOut = `${name}.telemetry.json`;
  for (const stale of [out, `${out}.diag`, telemetryOut]) rmSync(join(project, stale), { force: true });
  const env = { ...baseConfig, ...config };
  const result = spawnSync("bash", [runnerScript, "--invoke", "cli_main", ctx.stage2, "app.vibe", out, "main"], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...cleanEnv,
      ...env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: env.VIBE_HOME || join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      VIBE_CODEGEN_BODY_CACHE: "off",
      VIBE_CHECKED_MODULE_CACHE: "off",
      // Both spellings, so the answer does not depend on which one the
      // compile lane's default is: on opts in, off disables.
      VIBE_UNSTABLE_TYPING_DEP_ENV_REUSE_COMPILE: reuse ? "1" : "",
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: reuse ? "" : "1",
      VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryOut,
    },
  });
  const diagnostics = {
    status: result.status,
    stdout: normalize(result.stdout || "", ctx),
    stderr: normalize(result.stderr || "", ctx),
    diag: normalize(readText(join(project, `${out}.diag`)), ctx),
  };
  if (result.status !== 0 && !allowFailure) {
    fail(`${name} failed: ${[diagnostics.stderr, diagnostics.stdout, diagnostics.diag].filter(Boolean).join("\n")}`);
  }
  const observation = { name, diagnostics, bytes: null, telemetry: null, result: null };
  if (result.status === 0) {
    observation.bytes = readFileSync(join(project, out));
    observation.telemetry = telemetry(join(project, telemetryOut));
    observation.result = execute(ctx, name, join(project, out));
  }
  ctx.identities.push({
    build: name,
    lane: "compile",
    reuse,
    config: { ...env, VIBE_HOME: env.VIBE_HOME ? "<other>" : "<project>" },
    sources: sourceIdentity(project),
    status: result.status,
    diagnostics,
    artifact: observation.bytes ? sha256(observation.bytes) : null,
    result: observation.result,
    telemetry: observation.telemetry,
  });
  return observation;
}

// Run the compiled module's `main` and return what it printed: the observable
// result, so the comparison is about what the program DOES.
function execute(ctx, name, wasm) {
  const result = spawnSync("bash", [runnerScript, "--invoke", "main", wasm], {
    cwd: ctx.project,
    encoding: "utf8",
    env: { ...cleanEnv, VIBE_PREOPEN_DIR: ctx.project },
  });
  if (result.status !== 0) fail(`${name}: executing the module failed: ${(result.stderr || result.stdout || "").trim()}`);
  return (result.stdout || "").trim();
}

function expectCounts(name, actual, rechecked, transport) {
  if (actual.modules_planned !== 3 || actual.modules_rechecked !== rechecked ||
      actual.modules_reused_dependency_transport_env !== transport) {
    fail(`${name}: expected planned/rechecked/transport-reused 3/${rechecked}/${transport}, got ` +
      `${actual.modules_planned}/${actual.modules_rechecked}/${actual.modules_reused_dependency_transport_env}`);
  }
}

function expectHit(name, observation) {
  if (observation.telemetry.modules_reused_dependency_transport_env === 0) {
    fail(`${name} recorded no dependency-transport reuse, so the comparison below would be vacuous`);
  }
  expectCounts(name, observation.telemetry, 1, 2);
}

// The module, the diagnostics and the executed result all agree.
function expectSame(name, actual, fresh) {
  if (JSON.stringify(actual.diagnostics) !== JSON.stringify(fresh.diagnostics)) {
    fail(`${name}: the reuse-on diagnostics differ from a fresh reuse-off compile ` +
      `(${JSON.stringify(actual.diagnostics)} vs ${JSON.stringify(fresh.diagnostics)})`);
  }
  if (!actual.bytes !== !fresh.bytes || (actual.bytes && !actual.bytes.equals(fresh.bytes))) {
    fail(`${name}: the reuse-on compile differs from a fresh reuse-off compile ` +
      `(${actual.bytes?.length ?? "no"} vs ${fresh.bytes?.length ?? "no"} bytes)`);
  }
  if (actual.result !== fresh.result) {
    fail(`${name}: the reuse-on module executed ${actual.result}, a fresh compile ${fresh.result}`);
  }
}

function expectResult(name, observation, state, options) {
  const want = String(expectedResult(state, options));
  if (observation.result !== want) {
    fail(`${name}: the program executed ${observation.result}, but the fixture state computes ${want}`);
  }
}

function expectChanged(name, observation, before) {
  if (observation.bytes.equals(before.bytes)) fail(`${name} did not change the program, so it proved nothing`);
  if (observation.result === before.result) fail(`${name} did not change the executed result, so it proved nothing`);
}

// One fresh reuse-off compile of the current source in its own cache.
function fresh(ctx, name, state, options = {}) {
  const observation = build(ctx, name, { cache: ctx.dir(`${name}-cache`), reuse: false, ...options });
  if (observation.telemetry) expectCounts(`${name} (fresh, reuse off)`, observation.telemetry, 3, 0);
  if (observation.result !== null) expectResult(name, observation, state, resultOptions(options.config));
  return observation;
}

function resultOptions(config = {}) {
  return { mode: config.VIBE_CFG === "tdre_hi" ? 2 : 1 };
}

// ---- reuse records ---------------------------------------------------------

const aliasNamespace = "selfhost_typing_dependency_env_reuse_v10";
const witnessNamespace = "selfhost_typing_dependency_env_reuse_eligibility_v10";

// Overwrite every reuse record (aliases and witnesses) in a cache. Refuses
// when it finds none: a corruption that matched nothing proves nothing.
function corruptReuseRecords(cache) {
  const records = readdirSync(cache).filter((name) =>
    name.startsWith("vibe_selfhost_typing_dependency_env_reuse_"));
  if (records.length === 0) fail("the corruption found no reuse records in the cache, so it would prove nothing");
  for (const name of records) writeFileSync(join(cache, name), "TDRE11Agarbage");
  return records.length;
}

function witnessRecords(cache) {
  return bindingFiles(cache, witnessNamespace)
    .map((path) => ({ path, ...parseBinding(readFileSync(path, "utf8"), "TDRE10W") }));
}

// A target is the TypeEnv record a witness binds: found by its exact text, so
// the derivation of its path cannot drift from the compiler's.
function targetRecords(cache) {
  const texts = new Set(witnessRecords(cache).map((witness) => witness.targetText));
  return readdirSync(cache)
    .filter((name) => name.startsWith("vibe_selfhost_type_env_"))
    .map((name) => join(cache, name))
    .filter((path) => texts.has(readFileSync(path, "utf8")));
}

// The next element in a rotation that differs from `value`, so a splice puts a
// different VALID record in each place.
function rotate(values, index, value) {
  for (let step = 1; step < values.length; step += 1) {
    const candidate = values[(index + step) % values.length];
    if (candidate !== value) return candidate;
  }
  return null;
}

// Each corruption rewrites every record of ONE kind and leaves the other two
// intact, and must change every record it names: an edit that matched nothing
// passes while proving nothing.
const corruptions = {
  "alias-malformed": (cache) => rewrite("alias", bindingFiles(cache, aliasNamespace), () => "TDRE11Agarbage"),
  "alias-splice": (cache) => {
    const paths = bindingFiles(cache, aliasNamespace);
    const targets = paths.map((path) => parseAlias(readFileSync(path, "utf8")));
    return rewrite("alias", paths, (_text, i) => spliced("alias", rotate(targets, i, targets[i]), aliasText));
  },
  "witness-malformed": (cache) => rewrite("witness", bindingFiles(cache, witnessNamespace), () => "TDRE10W1:x"),
  "witness-splice": (cache) => {
    const witnesses = witnessRecords(cache);
    const texts = witnesses.map((witness) => witness.targetText);
    return rewrite("witness", witnesses.map((witness) => witness.path), (_text, i) =>
      spliced("witness", rotate(texts, i, texts[i]), (text) => witnessText(witnesses[i].input, witnesses[i].target, text)));
  },
  "target-malformed": (cache) => rewrite("target", targetRecords(cache), () => "version\t3\nenv\t"),
  "target-splice": (cache) => {
    const paths = targetRecords(cache);
    const texts = paths.map((path) => readFileSync(path, "utf8"));
    return rewrite("target", paths, (_text, i) => spliced("target", rotate(texts, i, texts[i]), (text) => text));
  },
};

function spliced(kind, other, render) {
  if (other === null) fail(`the ${kind} splice needs two distinct valid ${kind} records to exchange`);
  return render(other);
}

function rewrite(kind, paths, replacement) {
  if (paths.length === 0) fail(`the corruption found no ${kind} records in the cache, so it would prove nothing`);
  paths.forEach((path, i) => {
    const before = readFileSync(path, "utf8");
    const after = replacement(before, i);
    if (after === before) fail(`the ${kind} corruption left ${path} unchanged`);
    writeFileSync(path, after);
  });
  return paths.length;
}

// ---- sections --------------------------------------------------------------

function core(ctx, base) {
  const onCache = ctx.onCache;
  const report = {};

  // Each body edit HITS both consumers, changes what the program does, and
  // compiles to exactly the fresh module.
  let before = base;
  for (const [label, name, state] of [
    ["meaning edit", "edit", SA],
    ["private edit", "private", SP],
    ["capability edit", "capability", SC],
  ]) {
    setState(ctx.project, state);
    const warm = build(ctx, `${name}-on`, { cache: onCache, reuse: true });
    expectHit(`the ${label} with reuse on`, warm);
    expectChanged(`the ${label}`, warm, before);
    expectSame(label, warm, state === SA ? ctx.editFresh() : fresh(ctx, `${name}-fresh`, state));
    expectResult(label, warm, state);
    report[name.replace("-", "_")] = warm.telemetry;
    before = warm;
  }

  // A body error behind an unchanged public env: the same diagnostics as a
  // fresh compile, and the next good edit is compiled from the source.
  setState(ctx.project, SD);
  const diagOn = build(ctx, "diagnostic-on", { cache: onCache, reuse: true, allowFailure: true });
  const diagFresh = fresh(ctx, "diagnostic-fresh", SD, { allowFailure: true });
  if (diagOn.diagnostics.status === 0 || diagFresh.diagnostics.status === 0) fail("the body error compiled");
  if (!diagFresh.diagnostics.diag.includes("tdre_missing_helper")) {
    fail(`the body error's fresh diagnostics do not name it: ${JSON.stringify(diagFresh.diagnostics)}`);
  }
  expectSame("body error", diagOn, diagFresh);
  setState(ctx.project, SR);
  const recover = build(ctx, "recover-on", { cache: onCache, reuse: true });
  expectSame("recovery after a body error", recover, fresh(ctx, "recover-fresh", SR));
  expectResult("recovery after a body error", recover, SR);
  report.recovery = recover.telemetry;

  // Control: the same edit with reuse off in a warmed cache records no hit.
  const controlCache = ctx.dir("control-cache");
  setState(ctx.project, SK);
  build(ctx, "control-cold", { cache: controlCache, reuse: false });
  setState(ctx.project, SA);
  const control = build(ctx, "control-edit", { cache: controlCache, reuse: false });
  expectCounts("meaning edit with reuse off", control.telemetry, 3, 0);
  expectSame("meaning edit with reuse off", control, ctx.editFresh());
  report.reuse_off_control = control.telemetry;

  // Every record overwritten with garbage: no hit, and still the fresh program.
  corruptReuseRecords(onCache);
  setState(ctx.project, SG);
  const corrupt = build(ctx, "corrupt-on", { cache: onCache, reuse: true });
  expectCounts("corrupted reuse records", corrupt.telemetry, 3, 0);
  expectSame("corrupted reuse records", corrupt, fresh(ctx, "corrupt-fresh", SG));
  report.corrupted_records = corrupt.telemetry;

  // Interface edit: every consumer's key changes, so every consumer misses.
  setState(ctx.project, SI);
  const iface = build(ctx, "interface-on", { cache: onCache, reuse: true });
  expectCounts("interface edit with reuse on", iface.telemetry, 3, 0);
  expectSame("interface edit", iface, fresh(ctx, "interface-fresh", SI));
  report.interface_edit = iface.telemetry;
  return report;
}

// From the cold cache's snapshot, the meaning edit with one record kind
// corrupted. The uncorrupted snapshot must hit first.
function records(ctx) {
  const report = {};
  setState(ctx.project, SA);
  const control = build(ctx, "snapshot-on", { cache: ctx.copySnapshot("snapshot-cache"), reuse: true });
  expectHit("the uncorrupted snapshot", control);
  expectSame("the uncorrupted snapshot", control, ctx.editFresh());
  report.snapshot_control = control.telemetry;
  for (const [kind, corrupt] of Object.entries(corruptions)) {
    const cache = ctx.copySnapshot(`${kind}-cache`);
    const count = corrupt(cache);
    const warm = build(ctx, `${kind}-on`, { cache, reuse: true });
    expectCounts(`${kind} records`, warm.telemetry, 3, 0);
    expectSame(`${kind} records`, warm, ctx.editFresh());
    expectResult(`${kind} records`, warm, SA);
    report[kind.replace("-", "_")] = { records: count, telemetry: warm.telemetry };
  }
  return report;
}

// The meaning edit from the cold cache's snapshot, under a configuration the
// cold build did not use. Authority changes miss; the backend may hit.
function config(ctx) {
  const report = {};
  setState(ctx.project, SA);
  for (const [name, overrides, transport] of [
    ["cfg-flags", { VIBE_CFG: "tdre_hi" }, 0],
    ["error-row", { VIBE_CHECK_ERROR_ROW: "0" }, 0],
    ["resolution", { VIBE_HOME: join(ctx.project, ".other-home") }, 0],
    ["backend", { VIBE_RC: "0" }, 2],
  ]) {
    const warm = build(ctx, `${name}-on`, { cache: ctx.copySnapshot(`${name}-cache`), reuse: true, config: overrides });
    expectCounts(`the ${name} configuration change`, warm.telemetry, transport === 0 ? 3 : 1, transport);
    expectSame(`the ${name} configuration change`, warm, fresh(ctx, `${name}-fresh`, SA, { config: overrides }));
    expectResult(`the ${name} configuration change`, warm, SA, resultOptions(overrides));
    report[name.replace("-", "_")] = warm.telemetry;
  }
  return report;
}

// `vibe run`'s artifact under a grant change, through one reuse-on cache.
function runBuild(ctx, name, { cache, reuse, flags }) {
  const buildDir = join(ctx.project, `.run-${name}`);
  rmSync(buildDir, { recursive: true, force: true });
  const result = spawnSync("bash", [runnerScript, "--invoke", "cli_main", ctx.stage2, "run", ...flags, "run.vibex"], {
    cwd: ctx.project,
    encoding: "utf8",
    env: {
      ...cleanEnv,
      ...baseConfig,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_BUILD_DIR: buildDir,
      VIBE_HOME: join(ctx.project, ".home"),
      VIBE_PREOPEN_DIR: ctx.project,
      VIBE_CODEGEN_BODY_CACHE: "off",
      VIBE_CHECKED_MODULE_CACHE: "off",
      VIBE_UNSTABLE_TYPING_DEP_ENV_REUSE_COMPILE: reuse ? "1" : "",
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: reuse ? "" : "1",
    },
  });
  // `vibe run` compiles the artifact, then hands a launcher the run; the
  // plain host runner is not one, so it stops there. The artifact is what
  // this case compares, and its absence is a failure whatever the status.
  const artifact = join(buildDir, "run", "run.wasm");
  if (!existsSync(artifact)) {
    fail(`${name}: vibe run wrote no artifact (status ${result.status}): ${(result.stderr || result.stdout || "").trim()}`);
  }
  const bytes = readFileSync(artifact);
  const printed = execute(ctx, name, artifact);
  const match = /tdre=(-?\d+)/.exec(printed);
  if (!match) fail(`${name}: the run artifact printed no result: ${printed}`);
  ctx.identities.push({
    build: name, lane: "run", reuse, config: { ...baseConfig, flags },
    sources: sourceIdentity(ctx.project), status: result.status,
    diagnostics: { status: result.status, stdout: normalize(result.stdout || "", ctx), stderr: normalize(result.stderr || "", ctx) },
    artifact: sha256(bytes), result: match[1], telemetry: null,
  });
  return { name, bytes, result: match[1] };
}

function grants(ctx) {
  const cache = ctx.dir("run-cache");
  setState(ctx.project, SC);
  const full = runBuild(ctx, "run-full-on", { cache, reuse: true, flags: [] });
  const fullWant = String(expectedResult(SC, { granted: true }));
  if (full.result !== fullWant) fail(`run-full-on executed ${full.result}, the fixture with Env granted computes ${fullWant}`);
  setState(ctx.project, SR);
  const denied = runBuild(ctx, "run-deny-on", { cache, reuse: true, flags: ["--deny-env"] });
  const freshDenied = runBuild(ctx, "run-deny-fresh", { cache: ctx.dir("run-deny-fresh-cache"), reuse: false, flags: ["--deny-env"] });
  const deniedWant = String(expectedResult(SR, { granted: false }));
  if (denied.result !== deniedWant || freshDenied.result !== deniedWant) {
    fail(`the --deny-env run executed ${denied.result} (fresh ${freshDenied.result}), the fixture without Env computes ${deniedWant}`);
  }
  if (!denied.bytes.equals(freshDenied.bytes)) fail("the --deny-env run artifact differs from a fresh reuse-off run");
  const published = [...bindingFiles(cache, aliasNamespace), ...bindingFiles(cache, witnessNamespace)];
  if (published.length !== 0) {
    fail(`vibe run published ${published.length} transport reuse records: the grants case must now require and verify a hit`);
  }
  return { full_grants: full.result, deny_env: denied.result, transport_records: 0 };
}

function main() {
  const stage2Arg = process.argv[2];
  if (!stage2Arg) fail("usage: compile_typing_env_reuse_oracle.mjs <stage2.wasm>");
  const stage2 = resolve(process.cwd(), stage2Arg);
  if (sections.length !== allSections.length) {
    console.error(`compile-typing-env-reuse-oracle: NOTE running only ${sections.join(",")} (VIBE_COMPILE_TYPING_REUSE_ORACLE_SECTIONS)`);
  }
  const work = mkdtempSync(join(tmpdir(), "vibe-compile-typing-env-reuse-"));
  try {
    const dir = (name) => { const path = join(work, name); mkdirSync(path, { recursive: true }); return path; };
    const project = join(work, "project");
    makeProject(project, S0);
    const ctx = { stage2, work, project, dir, identities: [], onCache: dir("on-cache") };

    const base = build(ctx, "base-on", { cache: ctx.onCache, reuse: true });
    expectCounts("cold build with reuse on", base.telemetry, 3, 0);
    expectSame("cold build", base, fresh(ctx, "base-off", S0));
    expectResult("cold build", base, S0);
    // The cold cache as the meaning edit would find it, for the sections that
    // corrupt or reconfigure it without disturbing each other.
    const snapshot = join(work, "cold-snapshot");
    cpSync(ctx.onCache, snapshot, { recursive: true });
    ctx.copySnapshot = (name) => { const path = join(work, name); cpSync(snapshot, path, { recursive: true }); return path; };
    let editFresh = null;
    ctx.editFresh = () => {
      if (!editFresh) {
        const current = readFileSync(join(project, "dep.vibe"), "utf8");
        setState(project, SA);
        editFresh = fresh(ctx, "edit-fresh", SA);
        writeFileSync(join(project, "dep.vibe"), current);
      }
      return editFresh;
    };

    const report = { cold: base.telemetry };
    if (sections.includes("records")) report.records = records(ctx);
    if (sections.includes("config")) report.config = config(ctx);
    if (sections.includes("core")) report.core = core(ctx, base);
    if (sections.includes("grants")) report.grants = grants(ctx);

    console.log(JSON.stringify({
      schema: 2,
      scenario: "compile-lane-typing-dependency-transport-env-reuse",
      sections,
      compiler: { path: stage2, sha256: sha256(readFileSync(stage2)) },
      report,
      identities: ctx.identities,
    }));
  } finally {
    if (process.env.VIBE_COMPILE_TYPING_REUSE_ORACLE_KEEP_TMP === "1") console.error(`compile-typing-env-reuse-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

main();
