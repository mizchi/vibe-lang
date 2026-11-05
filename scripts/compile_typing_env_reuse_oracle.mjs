#!/usr/bin/env node
// #2728: is TypeEnv reuse on the COMPILE lane right on the one edit shape where
// it actually hits?
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
// compile with reuse off, never against the reuse lane's own earlier answer.
//
//   meaning edit    reuse hits every consumer (or the rest is vacuous), the
//                   program differs from the pre-edit one (or the edit proved
//                   nothing), and the bytes equal a fresh reuse-off compile
//   corrupt records every reuse record overwritten (the corruption must find
//                   records, or it proved nothing): no hit, everything
//                   rechecked, bytes equal a fresh compile
//   interface edit  the dependency's public env changes: every consumer
//                   misses, and the bytes equal a fresh compile
//   control         the same edit with reuse off records no hit, so the flag
//                   is what the hit counts measure
//
// The body cache and the checked-module cache are OFF in every build: either
// could replay a stale body and make the comparison pass for another reason.
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`compile-typing-env-reuse-oracle: ${message}`); };

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

// `dep` is imported by `mid` and `app`, and `mid` by `app`, so a dependency
// edit leaves two consumers to reuse. `mid` compares two unannotated arrays
// whose elements are both call results, so neither side gives the element
// type syntactically: that `==` resolves only through the typed-lowering row
// the checker records (#2391), which is the compile-only state a reuse hit
// republishes. The self-test strips those rows from the reused records and
// requires this oracle to fail. `app` compares a `derive(Eq)` struct declared
// in `dep`.
function depSource(k, name, extra = "") {
  return [
    `export fn tdre_k() -> Int { ${k} }`,
    `export fn tdre_name() -> String { "${name}" }`,
    "export fn tdre_two() -> Int { 2 }",
    "export struct TdrePt { x: Int; y: Int } derive(Eq)",
    "export fn tdre_pt(n: Int) -> TdrePt { TdrePt::{ x: n, y: tdre_k() } }",
    extra,
  ].join("\n");
}

function makeProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "dep.vibe"), depSource(1, "a"));
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
    "import ./dep.vibe { TdrePt, tdre_k, tdre_pt }",
    "fn main() -> Int {",
    "  let eq = if tdre_pt(1) == TdrePt::{ x: 1, y: 2 } { 7 } else { 0 }",
    "  tdre_mid(10) * 100 + tdre_k() + eq",
    "}",
  ].join("\n"));
}

// Meaning changes, the public env does not: same names, same signatures.
function meaningEdit(project, k) {
  writeFileSync(join(project, "dep.vibe"), depSource(k, k === 2 ? "bbb" : "cc"));
}

function interfaceEdit(project) {
  writeFileSync(join(project, "dep.vibe"), depSource(2, "bbb", "export fn tdre_extra() -> Int { 9 }"));
}

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

function build(stage2, project, cache, reuse, name) {
  const out = `${name}.wasm`;
  const telemetryOut = `${name}.telemetry.json`;
  const result = spawnSync("bash", [runnerScript, "--invoke", "cli_main", stage2, "app.vibe", out, "main"], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...cleanEnv,
      VIBE_RC: "1",
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "1",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home"),
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
  if (result.status !== 0) {
    const diagPath = join(project, `${out}.diag`);
    const diag = existsSync(diagPath) ? readFileSync(diagPath, "utf8") : "";
    fail(`${name} failed: ${[result.stderr, result.stdout, diag].map((text) => (text || "").trim()).filter(Boolean).join("\n")}`);
  }
  return { bytes: readFileSync(join(project, out)), telemetry: telemetry(join(project, telemetryOut)) };
}

function expectCounts(name, actual, rechecked, transport) {
  if (actual.modules_planned !== 3 || actual.modules_rechecked !== rechecked ||
      actual.modules_reused_dependency_transport_env !== transport) {
    fail(`${name}: expected planned/rechecked/transport-reused 3/${rechecked}/${transport}, got ` +
      `${actual.modules_planned}/${actual.modules_rechecked}/${actual.modules_reused_dependency_transport_env}`);
  }
}

function expectSameBytes(name, actual, fresh) {
  if (!actual.equals(fresh)) {
    fail(`${name}: the reuse-on compile differs from a fresh reuse-off compile (${actual.length} vs ${fresh.length} bytes)`);
  }
}

// Overwrite every reuse record (aliases and witnesses) in a cache. Refuses
// when it finds none: a corruption that matched nothing proves nothing.
function corruptReuseRecords(cache) {
  const records = readdirSync(cache).filter((name) =>
    name.startsWith("vibe_selfhost_typing_dependency_env_reuse_"));
  if (records.length === 0) fail("the corruption found no reuse records in the cache, so it would prove nothing");
  for (const name of records) writeFileSync(join(cache, name), "TDRE11Agarbage");
  return records.length;
}

function main() {
  const stage2Arg = process.argv[2];
  if (!stage2Arg) fail("usage: compile_typing_env_reuse_oracle.mjs <stage2.wasm>");
  const stage2 = resolve(process.cwd(), stage2Arg);
  const work = mkdtempSync(join(tmpdir(), "vibe-compile-typing-env-reuse-"));
  try {
    const dir = (name) => { const path = join(work, name); mkdirSync(path, { recursive: true }); return path; };
    const project = join(work, "project");
    makeProject(project);
    const onCache = dir("on-cache");

    const base = build(stage2, project, onCache, true, "base-on");
    expectCounts("cold build with reuse on", base.telemetry, 3, 0);
    const baseOff = build(stage2, project, dir("base-off-cache"), false, "base-off");
    expectSameBytes("cold build", base.bytes, baseOff.bytes);

    // Meaning edit: the hit, and the claim.
    meaningEdit(project, 2);
    const warm = build(stage2, project, onCache, true, "edit-on");
    if (warm.telemetry.modules_reused_dependency_transport_env === 0) {
      fail("the meaning edit recorded no dependency-transport reuse, so the comparison below would be vacuous");
    }
    expectCounts("meaning edit with reuse on", warm.telemetry, 1, 2);
    if (warm.bytes.equals(base.bytes)) fail("the meaning edit did not change the program, so it proved nothing");
    const fresh = build(stage2, project, dir("edit-fresh-cache"), false, "edit-fresh");
    expectCounts("meaning edit, fresh with reuse off", fresh.telemetry, 3, 0);
    expectSameBytes("meaning edit", warm.bytes, fresh.bytes);

    // Control: the same edit with reuse off in a warmed cache records no hit.
    const controlCache = dir("control-cache");
    meaningEdit(project, 3);
    build(stage2, project, controlCache, false, "control-cold");
    meaningEdit(project, 2);
    const control = build(stage2, project, controlCache, false, "control-edit");
    expectCounts("meaning edit with reuse off", control.telemetry, 3, 0);
    expectSameBytes("meaning edit with reuse off", control.bytes, fresh.bytes);

    // Corrupted records: no hit, and still the fresh program.
    corruptReuseRecords(onCache);
    meaningEdit(project, 3);
    const corrupt = build(stage2, project, onCache, true, "corrupt-on");
    expectCounts("corrupted reuse records", corrupt.telemetry, 3, 0);
    const corruptFresh = build(stage2, project, dir("corrupt-fresh-cache"), false, "corrupt-fresh");
    expectSameBytes("corrupted reuse records", corrupt.bytes, corruptFresh.bytes);

    // Interface edit: every consumer's key changes, so every consumer misses.
    interfaceEdit(project);
    const iface = build(stage2, project, onCache, true, "interface-on");
    expectCounts("interface edit with reuse on", iface.telemetry, 3, 0);
    const ifaceFresh = build(stage2, project, dir("interface-fresh-cache"), false, "interface-fresh");
    expectSameBytes("interface edit", iface.bytes, ifaceFresh.bytes);

    console.log(JSON.stringify({
      cold: base.telemetry,
      meaning_edit: warm.telemetry,
      meaning_edit_reuse_off: control.telemetry,
      corrupted_records: corrupt.telemetry,
      interface_edit: iface.telemetry,
    }));
  } finally {
    if (process.env.VIBE_COMPILE_TYPING_REUSE_ORACLE_KEEP_TMP === "1") console.error(`compile-typing-env-reuse-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

main();
