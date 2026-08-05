#!/usr/bin/env node
// Isolated production E2E oracle for the opt-in dependency transport-env
// typing reuse slice. It intentionally reads telemetry only; trace-only
// module-interface observations are rejected by the experiment and are never
// used to establish a production reuse key here.
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`experimental-typing-env-reuse-oracle: ${message}`); };

function telemetry(path) {
  const value = JSON.parse(readFileSync(path, "utf8"));
  if (value.schema !== 1) fail(`unexpected telemetry schema in ${path}`);
  for (const key of ["modules_planned", "modules_rechecked", "modules_reused", "modules_failed_or_blocked"]) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`invalid ${key} in ${path}`);
  }
  return value;
}

function makeProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> Int { 1 }\n");
  writeFileSync(join(project, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> Int { let _ = value()\n0 }\n");
}

function privateEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> Int { let ignored = 1\n2 }\n");
}

function publicEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> String { \"two\" }\n");
}

function makeChainProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "leaf.vibe"), "export fn value() -> Int { 1 }\nexport fn public_value() -> Int { 7 }\n");
  // Exported aliases make the leaf's public signature a direct transported
  // value at every hop while the callable result remains independently Int.
  writeFileSync(join(project, "middle_a.vibe"), "import ./leaf.vibe { value, public_value }\nexport fn middle_a_value() -> Int { value() }\nexport let propagated_a = public_value\n");
  writeFileSync(join(project, "middle_b.vibe"), "import ./middle_a.vibe { middle_a_value, propagated_a }\nexport fn middle_b_value() -> Int { middle_a_value() }\nexport let propagated_b = propagated_a\n");
  writeFileSync(join(project, "app.vibe"), "import ./middle_b.vibe { middle_b_value, propagated_b }\nfn main() -> Int { let _ = propagated_b\nmiddle_b_value() }\n");
}

function privateChainEdit(project) {
  writeFileSync(join(project, "leaf.vibe"), "export fn value() -> Int { let ignored = 1\n2 }\nexport fn public_value() -> Int { 7 }\n");
}

function publicChainEdit(project) {
  writeFileSync(join(project, "leaf.vibe"), "export fn value() -> Int { let ignored = 1\n2 }\nexport fn public_value() -> String { \"seven\" }\n");
}

function makeAmbientProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "leaf.vibe"), "export fn used() -> Int { 1 }\nexport fn ambient() -> Int { 2 }\n");
  writeFileSync(join(project, "middle.vibe"), "import ./leaf.vibe { used }\nexport fn middle() -> Int { used() }\n");
  writeFileSync(join(project, "app.vibe"), "import ./middle.vibe { middle }\nfn main() -> Int { middle() }\n");
}

function ambientOnlyTransportEdit(project) {
  // middle does not import ambient, so its own TypeEnv remains byte-identical;
  // app nevertheless receives leaf's changed TypeEnv as an ambient dep_env row.
  writeFileSync(join(project, "leaf.vibe"), "export fn used() -> Int { 1 }\nexport fn ambient() -> String { \"two\" }\n");
}

function makeOrderProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "a.vibe"), "export fn value() -> Int { 1 }\n");
  writeFileSync(join(project, "b.vibe"), "export fn value() -> Int { 2 }\n");
  // Equal exported spellings are deliberately renamed at import. This keeps
  // the checker result unambiguous while exercising the ordered environment
  // table whose first-match semantics protect future shadowing cases.
  writeFileSync(join(project, "app.vibe"), "import ./a.vibe { value as a_value }\nimport ./b.vibe { value as b_value }\nfn main() -> Int { a_value() + b_value() }\n");
}

function privateOrderEdit(project) {
  writeFileSync(join(project, "a.vibe"), "export fn value() -> Int { let ignored = 1\n1 }\n");
}

function makeTraitProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "helper.vibe"), "trait Base\ntrait OtherBase\ntrait Hidden: Base { hidden(Self) -> Int }\nimpl Base for Int\nimpl OtherBase for Int\nimpl Hidden for Int\nexport fn value() -> Int { 1 }\n");
  writeFileSync(join(project, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> Int { value() }\n");
}

function privateTraitModuleBodyEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "trait Base\ntrait OtherBase\ntrait Hidden: Base { hidden(Self) -> Int }\nimpl Base for Int\nimpl OtherBase for Int\nimpl Hidden for Int\nexport fn value() -> Int { let ignored = 1\n2 }\n");
}

function supertraitDependencyEdit(project) {
  // Only the hidden supertrait changes; the exported value signature, method,
  // and impl targets stay fixed.
  writeFileSync(join(project, "helper.vibe"), "trait Base\ntrait OtherBase\ntrait Hidden: OtherBase { hidden(Self) -> Int }\nimpl Base for Int\nimpl OtherBase for Int\nimpl Hidden for Int\nexport fn value() -> Int { let ignored = 1\n2 }\n");
}

function traitDependencyEdit(project) {
  // The app does not import the trait name. This independently proves that
  // hidden method and concrete-impl changes invalidate the v3 transport key.
  writeFileSync(join(project, "helper.vibe"), "trait Base\ntrait OtherBase\ntrait Hidden: Base { changed(Self) -> Int }\nimpl Base for Int\nimpl OtherBase for Int\nimpl Hidden for String\nexport fn value() -> Int { 1 }\n");
}

function check(stage2, project, cache, gate, name, allowFailure = false, extraEnv = {}) {
  const out = `${name}.out`;
  const telemetryOut = `${name}.telemetry.json`;
  const result = spawnSync("bash", [join(root, "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main", stage2, "app.vibe", out], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_CHECK_ONLY: "1",
      VIBE_INCREMENTAL_TELEMETRY_OUT: telemetryOut,
      VIBE_IMPORT_ABI: "raw",
      // Resolution authority is part of the TDRE4 logical input. Keep it
      // stable within each scenario; varying it per invocation would correctly
      // force a full check rather than exercise reuse.
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      ...(gate ? { VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "1" } : {}),
      ...extraEnv,
    },
  });
  if (result.status !== 0 && !allowFailure) fail(`${name} failed: ${(result.stderr || result.stdout).trim()}`);
  const outputPath = join(project, out);
  const telemetryPath = join(project, telemetryOut);
  try {
    if (result.status !== 0) return { output: readFileSync(`${outputPath}.diag`, "utf8"), status: result.status };
    return { output: readFileSync(outputPath, "utf8"), telemetry: telemetry(telemetryPath), status: result.status };
  } catch (error) {
    fail(`${name} omitted output or telemetry: ${error.message}`);
  }
}

function expectCounts(name, actual, rechecked, reused, planned = 2) {
  if (actual.modules_rechecked !== rechecked || actual.modules_reused !== reused || actual.modules_planned !== planned) {
    fail(`${name}: expected planned/rechecked/reused ${planned}/${rechecked}/${reused}, got ${actual.modules_planned}/${actual.modules_rechecked}/${actual.modules_reused}`);
  }
}

function segment(text) { return `${text.length}:${text}`; }
function parseSegment(text, start) {
  const colon = text.indexOf(":", start);
  if (colon < start || !/^\d+$/.test(text.slice(start, colon))) fail("invalid TDRE sidecar segment");
  const end = colon + 1 + Number(text.slice(start, colon));
  if (end > text.length) fail("truncated TDRE sidecar segment");
  return [text.slice(colon + 1, end), end];
}

function parseBinding(text, tag) {
  if (!text.startsWith(tag)) fail(`invalid ${tag} binding marker`);
  const [input, afterInput] = parseSegment(text, tag.length);
  const [target, afterTarget] = parseSegment(text, afterInput);
  const [targetText, end] = parseSegment(text, afterTarget);
  if (end !== text.length || !input || !target || !targetText) fail(`${tag} binding has trailing or empty data`);
  return { input, target, targetText };
}

function bindingFiles(cache, namespace) {
  return readdirSync(cache)
    .filter((name) => name.startsWith(`vibe_${namespace}_`))
    .map((name) => join(cache, name));
}

function appSidecar(cache, appSource) {
  const candidates = bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v4");
  const path = candidates.find((candidate) => {
    const text = readFileSync(candidate, "utf8");
    return text.startsWith("TDRE4A") && text.includes(appSource);
  });
  if (!path) fail(`non-vacuous TDRE4 app sidecar missing in ${basename(cache)}`);
  return { path, ...parseBinding(readFileSync(path, "utf8"), "TDRE4A") };
}

function otherSidecar(cache, target) {
  for (const path of bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v4")) {
    const binding = parseBinding(readFileSync(path, "utf8"), "TDRE4A");
    if (binding.target !== target) return { path, ...binding };
  }
  fail("second valid TDRE4 target missing");
}

function targetWitness(cache, target) {
  for (const path of bindingFiles(cache, "selfhost_typing_dependency_env_reuse_eligibility_v4")) {
    const binding = parseBinding(readFileSync(path, "utf8"), "TDRE4W");
    if (binding.target === target) return { path, ...binding };
  }
  fail(`bound TDRE4 witness missing for ${target}`);
}

function aliasText(input, target, targetText) {
  return `TDRE4A${segment(input)}${segment(target)}${segment(targetText)}`;
}

function witnessText(input, target, targetText) {
  return `TDRE4W${segment(input)}${segment(target)}${segment(targetText)}`;
}

const logicalInputTag = "vibe-typing-dependency-transport-env:v4";
function parseLogicalInput(input) {
  if (!input.startsWith(logicalInputTag)) fail("TDRE4 logical input tag changed");
  let cursor = logicalInputTag.length;
  const fields = [];
  for (let i = 0; i < 4; i += 1) {
    const [field, next] = parseSegment(input, cursor);
    fields.push(field);
    cursor = next;
  }
  const count = Number(fields[3]);
  if (!Number.isInteger(count) || count < 0) fail("invalid TDRE4 dep_env count");
  const rows = [];
  for (let i = 0; i < count; i += 1) {
    const [path, afterPath] = parseSegment(input, cursor);
    const [text, afterText] = parseSegment(input, afterPath);
    rows.push([path, text]);
    cursor = afterText;
  }
  if (cursor !== input.length) fail("TDRE4 logical input has trailing data");
  return { owner: fields[0], source: fields[1], resolutionSeed: fields[2], rows };
}

function logicalInputText({ owner, source, resolutionSeed, rows }) {
  return `${logicalInputTag}${segment(owner)}${segment(source)}${segment(resolutionSeed)}${segment(String(rows.length))}${rows.map(([path, text]) => `${segment(path)}${segment(text)}`).join("")}`;
}

function compactFingerprint(source) {
  const mod1 = 2147483647;
  const mod2 = 2147483629;
  let h1 = 17;
  let h2 = 29;
  for (let i = 0; i < source.length; i += 1) {
    const c = source.charCodeAt(i);
    h1 = (h1 * 131 + c + 1) % mod1;
    h2 = (h2 * 65599 + c + i + 1) % mod2;
  }
  return `${source.length}:${h1}:${h2}`;
}

// Derive the exact referenced TypeEnv filename from the target conservative
// fingerprint, mirroring @vibe/cache stable_cache_path. This avoids corrupting
// another module's env and makes the malformed-target case non-vacuous.
function referencedAppTargetEnv(stage2, cache, target) {
  // The stage compiler's bundled fingerprint can be one generation behind the
  // checkout's freshly regenerated source fingerprint, so read its adjacent
  // flattened module source rather than assuming the working-tree value.
  const stageSource = readFileSync(join(dirname(stage2), "cli_adapter_module_source.vibe"), "utf8");
  const codegen = stageSource.match(/codegen_fingerprint[\s\S]{0,200}?"([0-9a-f]{16})"/)?.[1];
  if (!codegen) fail("could not read stage compiler codegen fingerprint");
  const version = `v16|cg-${codegen}`;
  const token = compactFingerprint(`persistent-cache-${version}|${target}`).replaceAll(":", "_");
  const path = join(cache, `vibe_selfhost_type_env_v3_${token}.tsv`);
  try { readFileSync(path, "utf8"); }
  catch { fail("referenced app TypeEnv missing before corruption"); }
  return path;
}

function expectTraceLaneRejected(stage2, project, cache) {
  const out = "trace-rejected.out";
  const trace = "trace-rejected.json";
  const result = spawnSync("bash", [join(root, "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main", stage2, "app.vibe", out], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_CHECK_ONLY: "1",
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "1",
      VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: trace,
      VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "trace-lane-rejection",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home-trace-rejected"),
      VIBE_PREOPEN_DIR: project,
    },
  });
  if (result.status === 0) fail("trace lane unexpectedly accepted experimental reuse");
  const diag = readFileSync(join(project, `${out}.diag`), "utf8");
  if (!diag.includes("does not support VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT")) fail("trace lane rejection diagnostic changed");
}

function run(stage2) {
  const work = mkdtempSync(join(tmpdir(), "vibe-experimental-typing-env-reuse-"));
  try {
    const offProject = join(work, "off-project");
    const onProject = join(work, "on-project");
    const offCache = join(work, "off-cache");
    const onCache = join(work, "on-cache");
    makeProject(offProject);
    makeProject(onProject);

    const coldOff = check(stage2, offProject, offCache, false, "cold-off");
    const coldOn = check(stage2, onProject, onCache, true, "cold-on");
    expectCounts("cold off", coldOff.telemetry, 2, 0);
    expectCounts("cold on", coldOn.telemetry, 2, 0);
    if (coldOff.output !== coldOn.output) fail("cold gate-off/on output mismatch");

    const warmOn = check(stage2, onProject, onCache, true, "warm-on");
    expectCounts("warm on", warmOn.telemetry, 0, 2);

    privateEdit(offProject);
    privateEdit(onProject);
    const privateOff = check(stage2, offProject, offCache, false, "private-off");
    const privateOn = check(stage2, onProject, onCache, true, "private-on");
    expectCounts("private gate off", privateOff.telemetry, 2, 0);
    expectCounts("private gate on", privateOn.telemetry, 1, 1);
    if (privateOff.output !== privateOn.output) fail("private edit gate-off/on output mismatch");

    publicEdit(offProject);
    publicEdit(onProject);
    const publicOff = check(stage2, offProject, offCache, false, "public-off");
    const publicOn = check(stage2, onProject, onCache, true, "public-on");
    expectCounts("public gate off", publicOff.telemetry, 2, 0);
    expectCounts("public gate on", publicOn.telemetry, 2, 0);
    if (publicOff.output !== publicOn.output) fail("public edit gate-off/on output mismatch");
    expectTraceLaneRejected(stage2, onProject, onCache);

    const malformedProject = join(work, "malformed-target-project");
    const malformedCache = join(work, "malformed-target-cache");
    makeProject(malformedProject);
    check(stage2, malformedProject, malformedCache, true, "malformed-target-cold");
    const malformedSidecar = appSidecar(malformedCache, readFileSync(join(malformedProject, "app.vibe"), "utf8"));
    writeFileSync(referencedAppTargetEnv(stage2, malformedCache, malformedSidecar.target), "version\t3\nenv\t");
    privateEdit(malformedProject);
    const malformedTargetFallback = check(stage2, malformedProject, malformedCache, true, "malformed-target-fallback");
    expectCounts("malformed referenced target fallback", malformedTargetFallback.telemetry, 2, 0);

    const missingProject = join(work, "missing-target-project");
    const missingCache = join(work, "missing-target-cache");
    makeProject(missingProject);
    check(stage2, missingProject, missingCache, true, "missing-target-cold");
    const missingSidecar = appSidecar(missingCache, readFileSync(join(missingProject, "app.vibe"), "utf8"));
    rmSync(referencedAppTargetEnv(stage2, missingCache, missingSidecar.target));
    privateEdit(missingProject);
    const missingTargetFallback = check(stage2, missingProject, missingCache, true, "missing-target-fallback");
    expectCounts("missing referenced target fallback", missingTargetFallback.telemetry, 2, 0);

    const staleProject = join(work, "stale-target-project");
    const staleCache = join(work, "stale-target-cache");
    makeProject(staleProject);
    check(stage2, staleProject, staleCache, true, "stale-target-cold");
    const staleSidecar = appSidecar(staleCache, readFileSync(join(staleProject, "app.vibe"), "utf8"));
    writeFileSync(staleSidecar.path, aliasText(staleSidecar.input, "stale-conservative-target", staleSidecar.targetText));
    privateEdit(staleProject);
    const staleTargetFallback = check(stage2, staleProject, staleCache, true, "stale-target-fallback");
    expectCounts("stale referenced target fallback", staleTargetFallback.telemetry, 2, 0);

    const malformedSidecarProject = join(work, "malformed-sidecar-project");
    const malformedSidecarCache = join(work, "malformed-sidecar-cache");
    makeProject(malformedSidecarProject);
    check(stage2, malformedSidecarProject, malformedSidecarCache, true, "malformed-sidecar-cold");
    const corruptSidecar = appSidecar(malformedSidecarCache, readFileSync(join(malformedSidecarProject, "app.vibe"), "utf8"));
    writeFileSync(corruptSidecar.path, "malformed sidecar");
    privateEdit(malformedSidecarProject);
    const malformedSidecarFallback = check(stage2, malformedSidecarProject, malformedSidecarCache, true, "malformed-sidecar-fallback");
    expectCounts("malformed sidecar fallback", malformedSidecarFallback.telemetry, 2, 0);

    const validWrongProject = join(work, "valid-wrong-target-project");
    const validWrongCache = join(work, "valid-wrong-target-cache");
    makeProject(validWrongProject);
    check(stage2, validWrongProject, validWrongCache, true, "valid-wrong-target-cold");
    const validWrongApp = appSidecar(validWrongCache, readFileSync(join(validWrongProject, "app.vibe"), "utf8"));
    const validWrongOther = otherSidecar(validWrongCache, validWrongApp.target);
    // All target bytes are independently valid, but the other target's witness
    // is bound to another logical input. A target-only eligibility marker would
    // incorrectly accept this coherent-looking wrong-target alias.
    writeFileSync(validWrongApp.path, aliasText(validWrongApp.input, validWrongOther.target, validWrongOther.targetText));
    privateEdit(validWrongProject);
    const validWrongFallback = check(stage2, validWrongProject, validWrongCache, true, "valid-wrong-target-fallback");
    expectCounts("valid wrong target fallback", validWrongFallback.telemetry, 2, 0);

    const sidecarSpliceProject = join(work, "sidecar-splice-project");
    const sidecarSpliceCache = join(work, "sidecar-splice-cache");
    makeProject(sidecarSpliceProject);
    check(stage2, sidecarSpliceProject, sidecarSpliceCache, true, "sidecar-splice-cold");
    const sidecarSpliceApp = appSidecar(sidecarSpliceCache, readFileSync(join(sidecarSpliceProject, "app.vibe"), "utf8"));
    const sidecarSpliceOther = otherSidecar(sidecarSpliceCache, sidecarSpliceApp.target);
    writeFileSync(sidecarSpliceApp.path, readFileSync(sidecarSpliceOther.path, "utf8"));
    privateEdit(sidecarSpliceProject);
    const sidecarSpliceFallback = check(stage2, sidecarSpliceProject, sidecarSpliceCache, true, "sidecar-splice-fallback");
    expectCounts("cross-spliced sidecar fallback", sidecarSpliceFallback.telemetry, 2, 0);

    const witnessSpliceProject = join(work, "witness-splice-project");
    const witnessSpliceCache = join(work, "witness-splice-cache");
    makeProject(witnessSpliceProject);
    check(stage2, witnessSpliceProject, witnessSpliceCache, true, "witness-splice-cold");
    const witnessSpliceApp = appSidecar(witnessSpliceCache, readFileSync(join(witnessSpliceProject, "app.vibe"), "utf8"));
    const witnessSpliceOther = otherSidecar(witnessSpliceCache, witnessSpliceApp.target);
    const witnessSpliceWitness = targetWitness(witnessSpliceCache, witnessSpliceApp.target);
    writeFileSync(witnessSpliceWitness.path, witnessText(witnessSpliceApp.input, witnessSpliceApp.target, witnessSpliceOther.targetText));
    privateEdit(witnessSpliceProject);
    const witnessSpliceFallback = check(stage2, witnessSpliceProject, witnessSpliceCache, true, "witness-splice-fallback");
    expectCounts("cross-spliced witness fallback", witnessSpliceFallback.telemetry, 2, 0);

    const targetSpliceProject = join(work, "target-splice-project");
    const targetSpliceCache = join(work, "target-splice-cache");
    makeProject(targetSpliceProject);
    check(stage2, targetSpliceProject, targetSpliceCache, true, "target-splice-cold");
    const targetSpliceApp = appSidecar(targetSpliceCache, readFileSync(join(targetSpliceProject, "app.vibe"), "utf8"));
    const targetSpliceOther = otherSidecar(targetSpliceCache, targetSpliceApp.target);
    writeFileSync(referencedAppTargetEnv(stage2, targetSpliceCache, targetSpliceApp.target), targetSpliceOther.targetText);
    privateEdit(targetSpliceProject);
    const targetSpliceFallback = check(stage2, targetSpliceProject, targetSpliceCache, true, "target-splice-fallback");
    expectCounts("cross-spliced target fallback", targetSpliceFallback.telemetry, 2, 0);

    const missingWitnessProject = join(work, "missing-witness-project");
    const missingWitnessCache = join(work, "missing-witness-cache");
    makeProject(missingWitnessProject);
    check(stage2, missingWitnessProject, missingWitnessCache, true, "missing-witness-cold");
    const missingWitnessApp = appSidecar(missingWitnessCache, readFileSync(join(missingWitnessProject, "app.vibe"), "utf8"));
    rmSync(targetWitness(missingWitnessCache, missingWitnessApp.target).path);
    privateEdit(missingWitnessProject);
    const missingWitnessFallback = check(stage2, missingWitnessProject, missingWitnessCache, true, "missing-witness-fallback");
    expectCounts("missing witness fallback", missingWitnessFallback.telemetry, 2, 0);

    const malformedWitnessProject = join(work, "malformed-witness-project");
    const malformedWitnessCache = join(work, "malformed-witness-cache");
    makeProject(malformedWitnessProject);
    check(stage2, malformedWitnessProject, malformedWitnessCache, true, "malformed-witness-cold");
    const malformedWitnessApp = appSidecar(malformedWitnessCache, readFileSync(join(malformedWitnessProject, "app.vibe"), "utf8"));
    writeFileSync(targetWitness(malformedWitnessCache, malformedWitnessApp.target).path, "TDRE4W1:x");
    privateEdit(malformedWitnessProject);
    const malformedWitnessFallback = check(stage2, malformedWitnessProject, malformedWitnessCache, true, "malformed-witness-fallback");
    expectCounts("malformed witness fallback", malformedWitnessFallback.telemetry, 2, 0);

    const ambientProject = join(work, "ambient-dep-env-project");
    const ambientCache = join(work, "ambient-dep-env-cache");
    makeAmbientProject(ambientProject);
    const ambientCold = check(stage2, ambientProject, ambientCache, true, "ambient-cold");
    expectCounts("ambient cold", ambientCold.telemetry, 3, 0, 3);
    ambientOnlyTransportEdit(ambientProject);
    const ambientFallback = check(stage2, ambientProject, ambientCache, true, "ambient-change-fallback");
    expectCounts("ambient non-direct dep_env change fallback", ambientFallback.telemetry, 3, 0, 3);

    const resolutionProject = join(work, "resolution-seed-project");
    const resolutionCache = join(work, "resolution-seed-cache");
    makeProject(resolutionProject);
    check(stage2, resolutionProject, resolutionCache, true, "resolution-cold");
    privateEdit(resolutionProject);
    const resolutionFallback = check(stage2, resolutionProject, resolutionCache, true, "resolution-change-fallback", false, {
      VIBE_HOME: join(resolutionProject, ".other-home"),
    });
    expectCounts("resolution_env_seed change fallback", resolutionFallback.telemetry, 2, 0);

    const orderProject = join(work, "dep-env-order-project");
    const orderCache = join(work, "dep-env-order-cache");
    makeOrderProject(orderProject);
    const orderCold = check(stage2, orderProject, orderCache, true, "order-cold");
    expectCounts("dep_env order cold", orderCold.telemetry, 3, 0, 3);
    const orderApp = appSidecar(orderCache, readFileSync(join(orderProject, "app.vibe"), "utf8"));
    const parsedOrderInput = parseLogicalInput(orderApp.input);
    const orderPaths = parsedOrderInput.rows.map(([path]) => basename(path)).sort();
    if (parsedOrderInput.rows.length !== 2 || orderPaths[0] !== "a.vibe" || orderPaths[1] !== "b.vibe") {
      fail("TDRE4 app logical input omitted exact dep_env rows");
    }
    const swappedOrderInput = logicalInputText({
      ...parsedOrderInput,
      rows: [parsedOrderInput.rows[1], parsedOrderInput.rows[0]],
    });
    // Keep the sidecar at the correct key path but cross-splice a binding whose
    // two valid same-spelling dependency rows are reversed. Order-blind parsing
    // would accept the wrong witness/alias relationship.
    writeFileSync(orderApp.path, aliasText(swappedOrderInput, orderApp.target, orderApp.targetText));
    privateOrderEdit(orderProject);
    const orderFallback = check(stage2, orderProject, orderCache, true, "order-change-fallback");
    expectCounts("dep_env order/shadow fallback", orderFallback.telemetry, 2, 1, 3);

    const traitProject = join(work, "trait-project");
    const traitCache = join(work, "trait-cache");
    makeTraitProject(traitProject);
    check(stage2, traitProject, traitCache, true, "trait-cold");
    privateTraitModuleBodyEdit(traitProject);
    const traitPrivate = check(stage2, traitProject, traitCache, true, "trait-private-body");
    expectCounts("trait module private body reuse", traitPrivate.telemetry, 1, 1);
    supertraitDependencyEdit(traitProject);
    const supertraitFallback = check(stage2, traitProject, traitCache, true, "supertrait-dependency-fallback");
    expectCounts("supertrait-only dependency change fallback", supertraitFallback.telemetry, 2, 0);

    const traitChangeProject = join(work, "trait-change-project");
    const traitChangeCache = join(work, "trait-change-cache");
    makeTraitProject(traitChangeProject);
    check(stage2, traitChangeProject, traitChangeCache, true, "trait-change-cold");
    traitDependencyEdit(traitChangeProject);
    const traitFallback = check(stage2, traitChangeProject, traitChangeCache, true, "trait-dependency-fallback");
    expectCounts("trait method/impl dependency change fallback", traitFallback.telemetry, 2, 0);

    const chainProject = join(work, "chain-project");
    const chainCache = join(work, "chain-cache");
    makeChainProject(chainProject);
    const chainCold = check(stage2, chainProject, chainCache, true, "chain-cold");
    expectCounts("chain cold", chainCold.telemetry, 4, 0, 4);
    privateChainEdit(chainProject);
    const chainPrivate = check(stage2, chainProject, chainCache, true, "chain-private");
    expectCounts("chain private leaf body", chainPrivate.telemetry, 1, 3, 4);
    publicChainEdit(chainProject);
    const chainPublic = check(stage2, chainProject, chainCache, true, "chain-public");
    expectCounts("chain public leaf signature", chainPublic.telemetry, 4, 0, 4);

    // Diagnostics are also observationally identical: neither successful
    // aliases nor their fallback change checker error rendering.
    writeFileSync(join(offProject, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> String { missing_name }\n");
    writeFileSync(join(onProject, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> String { missing_name }\n");
    const diagnosticOff = check(stage2, offProject, offCache, false, "diagnostic-off", true);
    const diagnosticOn = check(stage2, onProject, onCache, true, "diagnostic-on", true);
    if (diagnosticOff.status === 0 || diagnosticOn.status === 0) fail("diagnostic scenario unexpectedly succeeded");
    if (diagnosticOff.output !== diagnosticOn.output) fail("diagnostic gate-off/on output mismatch");

    const noPublishProject = join(work, "diagnostic-no-publish-project");
    const noPublishCache = join(work, "diagnostic-no-publish-cache");
    makeProject(noPublishProject);
    const failingSource = "import ./helper.vibe { value }\nfn main() -> Int { missing_name }\n";
    writeFileSync(join(noPublishProject, "app.vibe"), failingSource);
    const noPublish = check(stage2, noPublishProject, noPublishCache, true, "diagnostic-no-publish", true);
    if (noPublish.status === 0) fail("diagnostic no-publish scenario unexpectedly succeeded");
    const noPublishAliases = bindingFiles(noPublishCache, "selfhost_typing_dependency_env_reuse_v4");
    const noPublishWitnesses = bindingFiles(noPublishCache, "selfhost_typing_dependency_env_reuse_eligibility_v4");
    if (noPublishAliases.length !== 1 || noPublishWitnesses.length !== 1) fail("diagnosed module published TDRE4 alias or witness");
    if (noPublishAliases.some((path) => readFileSync(path, "utf8").includes(failingSource))) fail("diagnosed owner source appeared in TDRE4 alias");

    console.log(JSON.stringify({
      schema: 1,
      scenario: "experimental-typing-dependency-transport-env-reuse",
      private_body: { gate_off: privateOff.telemetry, gate_on: privateOn.telemetry },
      public_interface: { gate_off: publicOff.telemetry, gate_on: publicOn.telemetry },
      malformed_target_fallback: malformedTargetFallback.telemetry,
      missing_target_fallback: missingTargetFallback.telemetry,
      stale_target_fallback: staleTargetFallback.telemetry,
      malformed_sidecar_fallback: malformedSidecarFallback.telemetry,
      valid_wrong_target_fallback: validWrongFallback.telemetry,
      cross_splice_fallbacks: {
        sidecar: sidecarSpliceFallback.telemetry,
        witness: witnessSpliceFallback.telemetry,
        target: targetSpliceFallback.telemetry,
      },
      witness_fallbacks: {
        missing: missingWitnessFallback.telemetry,
        malformed: malformedWitnessFallback.telemetry,
      },
      ambient_non_direct_dep_env_change_fallback: ambientFallback.telemetry,
      resolution_env_seed_change_fallback: resolutionFallback.telemetry,
      dep_env_order_shadow_fallback: orderFallback.telemetry,
      diagnostics_publish_nothing: true,
      trait_graph: {
        private_body_reuse: traitPrivate.telemetry,
        supertrait_change_fallback: supertraitFallback.telemetry,
        method_impl_change_fallback: traitFallback.telemetry,
      },
      multi_level_chain: { private_leaf_body: chainPrivate.telemetry, public_leaf_signature: chainPublic.telemetry },
    }));
  } finally {
    if (process.env.VIBE_EXPERIMENTAL_TYPING_ENV_REUSE_ORACLE_KEEP_TMP === "1") console.error(`experimental-typing-env-reuse-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) fail("usage: experimental_typing_env_reuse_oracle.mjs <stage2.wasm>");
  run(isAbsolute(process.argv[2]) ? process.argv[2] : resolve(process.cwd(), process.argv[2]));
}
