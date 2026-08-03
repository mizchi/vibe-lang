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

function makeTraitProject(project) {
  mkdirSync(project, { recursive: true });
  const trait = "trait Hidden\nimpl Hidden for Int\n";
  writeFileSync(join(project, "helper.vibe"), `${trait}export fn value() -> Int { 1 }\n`);
  writeFileSync(join(project, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> Int { value() }\n");
}

function privateTraitEdit(project) {
  const trait = "trait Hidden\nimpl Hidden for Int\n";
  writeFileSync(join(project, "helper.vibe"), `${trait}export fn value() -> Int { let ignored = 1\n2 }\n`);
}

function check(stage2, project, cache, gate, name, allowFailure = false) {
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
      VIBE_HOME: join(project, `.home-${name}`),
      VIBE_PREOPEN_DIR: project,
      ...(gate ? { VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "1" } : {}),
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

function appSidecar(cache, appSource) {
  const candidates = readdirSync(cache)
    .filter((name) => name.startsWith("vibe_selfhost_typing_dependency_env_reuse_v1_"))
    .map((name) => join(cache, name));
  const path = candidates.find((candidate) => {
    const text = readFileSync(candidate, "utf8");
    return text.startsWith("TDRE1") && text.includes(appSource);
  });
  if (!path) fail(`non-vacuous app sidecar missing in ${basename(cache)}`);
  const text = readFileSync(path, "utf8");
  const [input, afterInput] = parseSegment(text, 5);
  const [target, end] = parseSegment(text, afterInput);
  if (end !== text.length) fail("TDRE sidecar has trailing data");
  return { path, input, target };
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
  const version = `v14|cg-${codegen}`;
  const token = compactFingerprint(`persistent-cache-${version}|${target}`).replaceAll(":", "_");
  const path = join(cache, `vibe_selfhost_type_env_v2_${token}.tsv`);
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
    writeFileSync(referencedAppTargetEnv(stage2, malformedCache, malformedSidecar.target), "version\t1\nbind\tmain\t");
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
    writeFileSync(staleSidecar.path, `TDRE1${segment(staleSidecar.input)}${segment("stale-conservative-target")}`);
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

    const traitProject = join(work, "trait-project");
    const traitCache = join(work, "trait-cache");
    makeTraitProject(traitProject);
    check(stage2, traitProject, traitCache, true, "trait-cold");
    privateTraitEdit(traitProject);
    const traitFallback = check(stage2, traitProject, traitCache, true, "trait-private-fallback");
    expectCounts("trait graph fallback", traitFallback.telemetry, 2, 0);

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

    console.log(JSON.stringify({
      schema: 1,
      scenario: "experimental-typing-dependency-transport-env-reuse",
      private_body: { gate_off: privateOff.telemetry, gate_on: privateOn.telemetry },
      public_interface: { gate_off: publicOff.telemetry, gate_on: publicOn.telemetry },
      malformed_target_fallback: malformedTargetFallback.telemetry,
      missing_target_fallback: missingTargetFallback.telemetry,
      stale_target_fallback: staleTargetFallback.telemetry,
      malformed_sidecar_fallback: malformedSidecarFallback.telemetry,
      trait_fallback: traitFallback.telemetry,
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
