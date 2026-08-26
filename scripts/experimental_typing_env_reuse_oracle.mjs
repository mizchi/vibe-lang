#!/usr/bin/env node
// Production E2E oracle for default-on check-only TDRE8 TypeEnv reuse. The
// explicit disable flag is the conservative control. Trace-only observations
// force reuse off and are never used to establish a production reuse key.
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const fail = (message) => { throw new Error(`experimental-typing-env-reuse-oracle: ${message}`); };

function telemetry(path) {
  const value = JSON.parse(readFileSync(path, "utf8"));
  if (value.schema !== 2) fail(`unexpected telemetry schema in ${path}`);
  const keys = [
    "modules_planned", "modules_rechecked", "modules_reused", "parse_operations",
    "modules_failed_or_blocked", "current_source_parse_executions", "checker_executions",
    "modules_reused_conservative_fingerprint", "modules_reused_dependency_transport_env",
  ];
  if (Object.keys(value).length !== keys.length + 1 || keys.some((key) => !Object.hasOwn(value, key))) {
    fail(`unexpected telemetry fields in ${path}`);
  }
  for (const key of keys) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`invalid ${key} in ${path}`);
  }
  if (value.modules_reused_conservative_fingerprint + value.modules_reused_dependency_transport_env !== value.modules_reused) {
    fail(`reuse-class counters do not sum to modules_reused in ${path}`);
  }
  return value;
}

function makeProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> Int { 1 }\n");
  writeFileSync(join(project, "app.vibe"), "import ./helper.vibe { value }\nfn main() -> Int { let _ = value()\n0 }\n");
}

function makeCheckedRowProject(project) {
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, "helper.vibe"), "export fn boom() -> Int with Exception { throw(\"boom\") }\n");
  writeFileSync(join(project, "app.vibe"), "import ./helper.vibe { boom }\nfn main() -> Int { boom() }\n");
}

function commentEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "// implementation-only comment\nexport fn value() -> Int { 1 }\n");
}

function privateEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> Int { let ignored = 1\n2 }\n");
}

function publicEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> String { \"two\" }\n");
}

function privateStringEdit(project) {
  writeFileSync(join(project, "helper.vibe"), "export fn value() -> String { let ignored = 1\n\"three\" }\n");
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
  // The app imports neither this private trait nor a value bounded by it, so
  // selected trait authority must not leak this method/impl edit into v3.
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
      // Resolution authority is part of the TDRE8 logical input. Keep it
      // stable within each scenario; varying it per invocation would correctly
      // force a full check rather than exercise reuse.
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: gate ? "" : "1",
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "",
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

function compile(stage2, project, cache, enabled, name, allowFailure = false, extraEnv = {}) {
  const out = `${name}.wasm`;
  const result = spawnSync("bash", [join(root, "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main", stage2, "app.vibe", out, "main"], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_FS_COMPILE: "1",
      VIBE_RC: "0",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home"),
      VIBE_PREOPEN_DIR: project,
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: enabled ? "" : "1",
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "",
      ...extraEnv,
    },
  });
  const outputPath = join(project, out);
  if (result.status !== 0) {
    if (!allowFailure) fail(`${name} failed: ${(result.stderr || result.stdout).trim()}`);
    return { status: result.status, diagnostic: readFileSync(`${outputPath}.diag`, "utf8") };
  }
  return { status: result.status, bytes: readFileSync(outputPath) };
}

function expectCounts(name, actual, rechecked, reused, planned = 2, dependencyTransportReuse = 0) {
  if (actual.modules_rechecked !== rechecked || actual.modules_reused !== reused || actual.modules_planned !== planned) {
    fail(`${name}: expected planned/rechecked/reused ${planned}/${rechecked}/${reused}, got ${actual.modules_planned}/${actual.modules_rechecked}/${actual.modules_reused}`);
  }
  const conservativeReuse = reused - dependencyTransportReuse;
  if (actual.current_source_parse_executions !== rechecked || actual.checker_executions !== rechecked ||
      actual.modules_reused_conservative_fingerprint !== conservativeReuse ||
      actual.modules_reused_dependency_transport_env !== dependencyTransportReuse) {
    fail(`${name}: expected parse/check/conservative/TDRE8 ${rechecked}/${rechecked}/${conservativeReuse}/${dependencyTransportReuse}, got ${actual.current_source_parse_executions}/${actual.checker_executions}/${actual.modules_reused_conservative_fingerprint}/${actual.modules_reused_dependency_transport_env}`);
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
  const candidates = bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v8");
  const path = candidates.find((candidate) => {
    const text = readFileSync(candidate, "utf8");
    return text.startsWith("TDRE8A") && text.includes(appSource);
  });
  if (!path) fail(`non-vacuous TDRE8 app sidecar missing in ${basename(cache)}`);
  return { path, ...parseBinding(readFileSync(path, "utf8"), "TDRE8A") };
}

function otherSidecar(cache, target) {
  for (const path of bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v8")) {
    const binding = parseBinding(readFileSync(path, "utf8"), "TDRE8A");
    if (binding.target !== target) return { path, ...binding };
  }
  fail("second valid TDRE8 target missing");
}

function targetWitness(cache, target) {
  for (const path of bindingFiles(cache, "selfhost_typing_dependency_env_reuse_eligibility_v8")) {
    const binding = parseBinding(readFileSync(path, "utf8"), "TDRE8W");
    if (binding.target === target) return { path, ...binding };
  }
  fail(`bound TDRE8 witness missing for ${target}`);
}

function aliasText(input, target, targetText) {
  return `TDRE8A${segment(input)}${segment(target)}${segment(targetText)}`;
}

function witnessText(input, target, targetText) {
  return `TDRE8W${segment(input)}${segment(target)}${segment(targetText)}`;
}

const logicalInputTag = "vibe-typing-dependency-transport-env:v8";
function parseLogicalInput(input) {
  if (!input.startsWith(logicalInputTag)) fail("TDRE8 logical input tag changed");
  let cursor = logicalInputTag.length;
  const fields = [];
  for (let i = 0; i < 5; i += 1) {
    const [field, next] = parseSegment(input, cursor);
    fields.push(field);
    cursor = next;
  }
  if (fields[2] !== "checked" && fields[2] !== "unchecked") fail("invalid TDRE8 typing semantics seed");
  const count = Number(fields[4]);
  if (!Number.isInteger(count) || count < 0) fail("invalid TDRE8 dep_env count");
  const rows = [];
  for (let i = 0; i < count; i += 1) {
    const [path, afterPath] = parseSegment(input, cursor);
    const [text, afterText] = parseSegment(input, afterPath);
    rows.push([path, text]);
    cursor = afterText;
  }
  if (cursor !== input.length) fail("TDRE8 logical input has trailing data");
  return { owner: fields[0], source: fields[1], typingSemantics: fields[2], resolutionSeed: fields[3], rows };
}

function logicalInputText({ owner, source, typingSemantics, resolutionSeed, rows }) {
  return `${logicalInputTag}${segment(owner)}${segment(source)}${segment(typingSemantics)}${segment(resolutionSeed)}${segment(String(rows.length))}${rows.map(([path, text]) => `${segment(path)}${segment(text)}`).join("")}`;
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

function stageCodegenFingerprint(stage2) {
  // The stage compiler's bundled fingerprint can be one generation behind the
  // checkout's freshly regenerated source fingerprint, so read its adjacent
  // flattened module source rather than assuming the working-tree value.
  const stageSource = readFileSync(join(dirname(stage2), "cli_adapter_module_source.vibe"), "utf8");
  const codegen = stageSource.match(/codegen_fingerprint[\s\S]{0,200}?"([0-9a-f]{16})"/)?.[1];
  if (!codegen) fail("could not read stage compiler codegen fingerprint");
  return codegen;
}

function stableCachePath(cache, version, prefix, seed, suffix) {
  const token = compactFingerprint(`persistent-cache-${version}|${seed}`).replaceAll(":", "_");
  return join(cache, `vibe_${prefix}_${token}${suffix}`);
}

function typeEnvPath(stage2, cache, target, major = "v22") {
  return stableCachePath(cache, `${major}|cg-${stageCodegenFingerprint(stage2)}`, "selfhost_type_env_v8", target, ".tsv");
}

// Derive the exact referenced TypeEnv filename from the target conservative
// fingerprint, mirroring @vibe/cache stable_cache_path. This avoids corrupting
// another module's env and makes the malformed-target case non-vacuous.
function referencedAppTargetEnv(stage2, cache, target) {
  const path = typeEnvPath(stage2, cache, target);
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
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: "",
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "1",
      VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: trace,
      VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "trace-lane-rejection",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home-trace-rejected"),
      VIBE_PREOPEN_DIR: project,
    },
  });
  if (result.status === 0) fail("trace lane unexpectedly accepted explicit legacy reuse");
  const diagPath = join(project, `${out}.diag`);
  const diagnostic = `${result.stderr || ""}\n${result.stdout || ""}\n${existsSync(diagPath) ? readFileSync(diagPath, "utf8") : ""}`;
  if (!diagnostic.includes("does not support VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT")) fail("trace lane rejection diagnostic changed");
}

function traceForcedOff(stage2, project, cache) {
  const beforeAliases = bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v8").length;
  const beforeWitnesses = bindingFiles(cache, "selfhost_typing_dependency_env_reuse_eligibility_v8").length;
  const result = check(stage2, project, cache, true, "trace-forced-off", false, {
    VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: "trace-forced-off.json",
    VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: "trace-forced-off",
  });
  expectCounts("ordinary trace forced off", result.telemetry, 2, 0);
  if (!existsSync(join(project, "trace-forced-off.json"))) fail("ordinary trace omitted observation sidecar");
  if (bindingFiles(cache, "selfhost_typing_dependency_env_reuse_v8").length !== beforeAliases ||
      bindingFiles(cache, "selfhost_typing_dependency_env_reuse_eligibility_v8").length !== beforeWitnesses) {
    fail("observation-only trace published TDRE8 state");
  }
  return result.telemetry;
}

function expectInvalidEnvRejected(stage2, project, cache, variable, value) {
  const out = `invalid-${variable}.out`;
  const result = spawnSync("bash", [join(root, "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main", stage2, "app.vibe", out], {
    cwd: project,
    encoding: "utf8",
    env: {
      ...process.env,
      VIBE_BUILD_CACHE_DIR: cache,
      VIBE_CHECK_ONLY: "1",
      VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE: "",
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "",
      VIBE_IMPORT_ABI: "raw",
      VIBE_HOME: join(project, ".home-invalid-env"),
      VIBE_PREOPEN_DIR: project,
      [variable]: value,
    },
  });
  if (result.status === 0) fail(`${variable}=${value} unexpectedly accepted`);
  const diagPath = join(project, `${out}.diag`);
  const diagnostic = `${result.stderr || ""}\n${result.stdout || ""}\n${existsSync(diagPath) ? readFileSync(diagPath, "utf8") : ""}`;
  if (!diagnostic.includes(variable)) fail(`${variable} rejection omitted strict diagnostic`);
}

function expectV21Isolation(stage2, work) {
  const project = join(work, "v21-isolation-project");
  const currentCache = join(work, "v21-isolation-current-cache");
  const oldCache = join(work, "v21-isolation-old-cache");
  makeProject(project);
  check(stage2, project, currentCache, true, "v21-source-cold");
  mkdirSync(oldCache, { recursive: true });
  const oldVersion = `v21|cg-${stageCodegenFingerprint(stage2)}`;
  for (const path of bindingFiles(currentCache, "selfhost_typing_dependency_env_reuse_v8")) {
    const text = readFileSync(path, "utf8");
    const binding = parseBinding(text, "TDRE8A");
    writeFileSync(stableCachePath(oldCache, oldVersion, "selfhost_typing_dependency_env_reuse_v8", binding.input, ".txt"), text);
    writeFileSync(typeEnvPath(stage2, oldCache, binding.target, "v21"), readFileSync(typeEnvPath(stage2, currentCache, binding.target), "utf8"));
  }
  for (const path of bindingFiles(currentCache, "selfhost_typing_dependency_env_reuse_eligibility_v8")) {
    const text = readFileSync(path, "utf8");
    const binding = parseBinding(text, "TDRE8W");
    writeFileSync(stableCachePath(oldCache, oldVersion, "selfhost_typing_dependency_env_reuse_eligibility_v8", binding.target, ".txt"), text);
    writeFileSync(typeEnvPath(stage2, oldCache, binding.target, "v21"), readFileSync(typeEnvPath(stage2, currentCache, binding.target), "utf8"));
  }
  if (bindingFiles(oldCache, "selfhost_typing_dependency_env_reuse_v8").length === 0) fail("v21 isolation fixture omitted valid old aliases");
  const isolated = check(stage2, project, oldCache, true, "v21-isolated-default");
  expectCounts("v21 namespace isolation", isolated.telemetry, 2, 0);
  return isolated.telemetry;
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
    expectCounts("warm default-on", warmOn.telemetry, 0, 2);

    // #1669: checker semantics are cache authority. An unchecked successful
    // publication must never satisfy a later checked invocation, and a checked
    // partial cache from a rejected run must not satisfy unchecked mode either.
    const uncheckedFirstProject = join(work, "row-mode-unchecked-first-project");
    const uncheckedFirstCache = join(work, "row-mode-unchecked-first-cache");
    makeCheckedRowProject(uncheckedFirstProject);
    const uncheckedCold = check(stage2, uncheckedFirstProject, uncheckedFirstCache, true, "row-unchecked-cold", false, { VIBE_CHECK_ERROR_ROW: "0" });
    expectCounts("unchecked mode cold", uncheckedCold.telemetry, 2, 0);
    const checkedAfterUnchecked = check(stage2, uncheckedFirstProject, uncheckedFirstCache, true, "row-checked-after-unchecked", true, { VIBE_CHECK_ERROR_ROW: "1" });
    if (checkedAfterUnchecked.status === 0 || !checkedAfterUnchecked.output.includes("missing { Exception }")) fail("checked mode reused unchecked typing result");
    const uncheckedWarm = check(stage2, uncheckedFirstProject, uncheckedFirstCache, true, "row-unchecked-warm", false, { VIBE_CHECK_ERROR_ROW: "0" });
    expectCounts("unchecked same-mode warm", uncheckedWarm.telemetry, 0, 2);

    const checkedFirstProject = join(work, "row-mode-checked-first-project");
    const checkedFirstCache = join(work, "row-mode-checked-first-cache");
    makeCheckedRowProject(checkedFirstProject);
    const checkedCold = check(stage2, checkedFirstProject, checkedFirstCache, true, "row-checked-cold", true, { VIBE_CHECK_ERROR_ROW: "1" });
    if (checkedCold.status === 0 || !checkedCold.output.includes("missing { Exception }")) fail("cold checked mode did not reject row-less caller");
    const uncheckedAfterChecked = check(stage2, checkedFirstProject, checkedFirstCache, true, "row-unchecked-after-checked", false, { VIBE_CHECK_ERROR_ROW: "0" });
    expectCounts("unchecked after checked mode isolation", uncheckedAfterChecked.telemetry, 2, 0);
    const modeSeeds = bindingFiles(uncheckedFirstCache, "selfhost_typing_dependency_env_reuse_v8").map((path) => parseLogicalInput(parseBinding(readFileSync(path, "utf8"), "TDRE8A").input).typingSemantics);
    if (!modeSeeds.includes("checked") || !modeSeeds.includes("unchecked")) fail("TDRE8 aliases did not retain disjoint typing semantics seeds");
    const legacyCompat = check(stage2, onProject, onCache, true, "legacy-compat", false, {
      VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE: "1",
    });
    expectCounts("legacy 1 compatibility no-op", legacyCompat.telemetry, 0, 2);
    commentEdit(onProject);
    const commentOn = check(stage2, onProject, onCache, true, "comment-on");
    expectCounts("comment-only consumer reuse", commentOn.telemetry, 1, 1, 2, 1);

    const compileControlProject = join(work, "compile-control-project");
    const compileDefaultProject = join(work, "compile-default-project");
    makeProject(compileControlProject);
    makeProject(compileDefaultProject);
    const compileControl = compile(stage2, compileControlProject, join(work, "compile-control-cache"), false, "compile-control");
    const compileDefault = compile(stage2, compileDefaultProject, join(work, "compile-default-cache"), true, "compile-default");
    if (!compileControl.bytes.equals(compileDefault.bytes)) fail("FS compile default-on/explicit-disable output mismatch");

    const buildUncheckedFirstProject = join(work, "build-row-unchecked-first-project");
    const buildUncheckedFirstCache = join(work, "build-row-unchecked-first-cache");
    makeCheckedRowProject(buildUncheckedFirstProject);
    const buildUncheckedCold = compile(stage2, buildUncheckedFirstProject, buildUncheckedFirstCache, true, "build-row-unchecked-cold", false, { VIBE_CHECK_ERROR_ROW: "0" });
    const buildUncheckedWarm = compile(stage2, buildUncheckedFirstProject, buildUncheckedFirstCache, true, "build-row-unchecked-warm", false, { VIBE_CHECK_ERROR_ROW: "0" });
    if (!buildUncheckedCold.bytes.equals(buildUncheckedWarm.bytes)) fail("same-mode unchecked build cache changed output");
    const buildCheckedAfterUnchecked = compile(stage2, buildUncheckedFirstProject, buildUncheckedFirstCache, true, "build-row-checked-after-unchecked", true, { VIBE_CHECK_ERROR_ROW: "1" });
    if (buildCheckedAfterUnchecked.status === 0 || !buildCheckedAfterUnchecked.diagnostic.includes("missing { Exception }")) fail("checked build reused unchecked compiled artifact");

    const buildCheckedFirstProject = join(work, "build-row-checked-first-project");
    const buildCheckedFirstCache = join(work, "build-row-checked-first-cache");
    makeCheckedRowProject(buildCheckedFirstProject);
    const buildCheckedCold = compile(stage2, buildCheckedFirstProject, buildCheckedFirstCache, true, "build-row-checked-cold", true, { VIBE_CHECK_ERROR_ROW: "1" });
    const buildCheckedWarm = compile(stage2, buildCheckedFirstProject, buildCheckedFirstCache, true, "build-row-checked-warm", true, { VIBE_CHECK_ERROR_ROW: "1" });
    if (buildCheckedCold.status === 0 || buildCheckedWarm.status === 0 || !buildCheckedCold.diagnostic.includes("missing { Exception }") || !buildCheckedWarm.diagnostic.includes("missing { Exception }")) fail("checked cold/warm build did not reject row-less caller");
    const buildUncheckedAfterChecked = compile(stage2, buildCheckedFirstProject, buildCheckedFirstCache, true, "build-row-unchecked-after-checked", false, { VIBE_CHECK_ERROR_ROW: "0" });

    privateEdit(offProject);
    privateEdit(onProject);
    const privateOff = check(stage2, offProject, offCache, false, "private-off");
    const privateOn = check(stage2, onProject, onCache, true, "private-on");
    expectCounts("private gate off", privateOff.telemetry, 2, 0);
    expectCounts("private gate on", privateOn.telemetry, 1, 1, 2, 1);
    if (privateOff.output !== privateOn.output) fail("private edit gate-off/on output mismatch");

    publicEdit(offProject);
    publicEdit(onProject);
    const publicOff = check(stage2, offProject, offCache, false, "public-off");
    const publicOn = check(stage2, onProject, onCache, true, "public-on");
    expectCounts("public gate off", publicOff.telemetry, 2, 0);
    expectCounts("public gate on", publicOn.telemetry, 2, 0);
    if (publicOff.output !== publicOn.output) fail("public edit control/default output mismatch");
    privateStringEdit(onProject);
    const traceForcedOffTelemetry = traceForcedOff(stage2, onProject, onCache);
    const postTraceDefault = check(stage2, onProject, onCache, true, "post-trace-default");
    expectCounts("normal check after trace resets default policy", postTraceDefault.telemetry, 0, 2);
    expectTraceLaneRejected(stage2, onProject, onCache);
    expectInvalidEnvRejected(stage2, onProject, onCache, "VIBE_DISABLE_TYPING_DEPENDENCY_ENV_REUSE", "true");
    expectInvalidEnvRejected(stage2, onProject, onCache, "VIBE_EXPERIMENTAL_TYPING_DEPENDENCY_ENV_REUSE", "0");
    const v21Isolation = expectV21Isolation(stage2, work);

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
    writeFileSync(targetWitness(malformedWitnessCache, malformedWitnessApp.target).path, "TDRE8W1:x");
    privateEdit(malformedWitnessProject);
    const malformedWitnessFallback = check(stage2, malformedWitnessProject, malformedWitnessCache, true, "malformed-witness-fallback");
    expectCounts("malformed witness fallback", malformedWitnessFallback.telemetry, 2, 0);

    const ambientProject = join(work, "ambient-dep-env-project");
    const ambientCache = join(work, "ambient-dep-env-cache");
    makeAmbientProject(ambientProject);
    const ambientCold = check(stage2, ambientProject, ambientCache, true, "ambient-cold");
    expectCounts("ambient cold", ambientCold.telemetry, 3, 0, 3);
    const ambientColdApp = appSidecar(ambientCache, readFileSync(join(ambientProject, "app.vibe"), "utf8"));
    const ambientColdInput = parseLogicalInput(ambientColdApp.input);
    if (ambientColdInput.rows.length !== 1 || basename(ambientColdInput.rows[0][0]) !== "middle.vibe") {
      fail("TDRE8 app logical input was not the exact direct-dependency projection");
    }
    ambientOnlyTransportEdit(ambientProject);
    const ambientReuse = check(stage2, ambientProject, ambientCache, true, "ambient-change-reuse");
    expectCounts("ambient non-direct cache change reuse", ambientReuse.telemetry, 2, 1, 3, 1);
    const ambientWarmApp = appSidecar(ambientCache, readFileSync(join(ambientProject, "app.vibe"), "utf8"));
    if (ambientWarmApp.input !== ambientColdApp.input || ambientWarmApp.path !== ambientColdApp.path) {
      fail("ambient non-direct cache mutation changed the app TDRE8 input key");
    }

    const resolutionProject = join(work, "resolution-seed-project");
    const resolutionCache = join(work, "resolution-seed-cache");
    makeProject(resolutionProject);
    check(stage2, resolutionProject, resolutionCache, true, "resolution-cold");
    privateEdit(resolutionProject);
    const resolutionFallback = check(stage2, resolutionProject, resolutionCache, true, "resolution-change-fallback", false, {
      VIBE_HOME: join(resolutionProject, ".other-home"),
    });
    expectCounts("resolution_env_seed change fallback", resolutionFallback.telemetry, 2, 0);

    const rowProject = join(work, "dep-env-row-project");
    const rowCache = join(work, "dep-env-row-cache");
    makeProject(rowProject);
    check(stage2, rowProject, rowCache, true, "row-cold");
    const rowApp = appSidecar(rowCache, readFileSync(join(rowProject, "app.vibe"), "utf8"));
    const parsedRowInput = parseLogicalInput(rowApp.input);
    if (parsedRowInput.rows.length !== 1 || basename(parsedRowInput.rows[0][0]) !== "helper.vibe") {
      fail("TDRE8 direct dependency row missing before row mutation");
    }
    const changedRowInput = logicalInputText({
      ...parsedRowInput,
      rows: [[`${parsedRowInput.rows[0][0]}.changed`, parsedRowInput.rows[0][1]]],
    });
    writeFileSync(rowApp.path, aliasText(changedRowInput, rowApp.target, rowApp.targetText));
    privateEdit(rowProject);
    const rowFallback = check(stage2, rowProject, rowCache, true, "row-change-fallback");
    expectCounts("direct dep_env row fallback", rowFallback.telemetry, 2, 0);

    const orderProject = join(work, "dep-env-order-project");
    const orderCache = join(work, "dep-env-order-cache");
    makeOrderProject(orderProject);
    const orderCold = check(stage2, orderProject, orderCache, true, "order-cold");
    expectCounts("dep_env order cold", orderCold.telemetry, 3, 0, 3);
    const orderApp = appSidecar(orderCache, readFileSync(join(orderProject, "app.vibe"), "utf8"));
    const parsedOrderInput = parseLogicalInput(orderApp.input);
    const orderPaths = parsedOrderInput.rows.map(([path]) => basename(path)).sort();
    if (parsedOrderInput.rows.length !== 2 || orderPaths[0] !== "a.vibe" || orderPaths[1] !== "b.vibe") {
      fail("TDRE8 app logical input omitted exact dep_env rows");
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
    expectCounts("trait module private body reuse", traitPrivate.telemetry, 1, 1, 2, 1);
    supertraitDependencyEdit(traitProject);
    const supertraitFallback = check(stage2, traitProject, traitCache, true, "supertrait-dependency-fallback");
    expectCounts("unselected supertrait dependency change reuses consumer", supertraitFallback.telemetry, 1, 1, 2, 1);

    const traitChangeProject = join(work, "trait-change-project");
    const traitChangeCache = join(work, "trait-change-cache");
    makeTraitProject(traitChangeProject);
    check(stage2, traitChangeProject, traitChangeCache, true, "trait-change-cold");
    traitDependencyEdit(traitChangeProject);
    const traitFallback = check(stage2, traitChangeProject, traitChangeCache, true, "trait-dependency-fallback");
    expectCounts("unselected trait method/impl dependency change reuses consumer", traitFallback.telemetry, 1, 1, 2, 1);

    const chainProject = join(work, "chain-project");
    const chainCache = join(work, "chain-cache");
    makeChainProject(chainProject);
    const chainCold = check(stage2, chainProject, chainCache, true, "chain-cold");
    expectCounts("chain cold", chainCold.telemetry, 4, 0, 4);
    privateChainEdit(chainProject);
    const chainPrivate = check(stage2, chainProject, chainCache, true, "chain-private");
    expectCounts("chain private leaf body", chainPrivate.telemetry, 1, 3, 4, 3);
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
    const noPublishAliases = bindingFiles(noPublishCache, "selfhost_typing_dependency_env_reuse_v8");
    const noPublishWitnesses = bindingFiles(noPublishCache, "selfhost_typing_dependency_env_reuse_eligibility_v8");
    if (noPublishAliases.length !== 1 || noPublishWitnesses.length !== 1) fail("diagnosed module published TDRE8 alias or witness");
    if (noPublishAliases.some((path) => readFileSync(path, "utf8").includes(failingSource))) fail("diagnosed owner source appeared in TDRE8 alias");

    console.log(JSON.stringify({
      schema: 2,
      scenario: "production-typing-dependency-transport-env-reuse",
      default_policy: {
        cold: coldOn.telemetry,
        warm: warmOn.telemetry,
        legacy_compatibility: legacyCompat.telemetry,
        explicit_disable_control: coldOff.telemetry,
        trace_forced_off: traceForcedOffTelemetry,
        post_trace_default: postTraceDefault.telemetry,
        v21_namespace_isolation: v21Isolation,
        conservative_compile_output_parity: true,
        invalid_env_diagnostics: true,
        checked_error_row_mode_isolation: {
          unchecked_cold: uncheckedCold.telemetry,
          unchecked_same_mode_warm: uncheckedWarm.telemetry,
          checked_after_unchecked_rejected: true,
          unchecked_after_checked: uncheckedAfterChecked.telemetry,
          compiled_artifact: {
            unchecked_same_mode_bytes_equal: buildUncheckedCold.bytes.equals(buildUncheckedWarm.bytes),
            checked_after_unchecked_rejected: true,
            checked_cold_and_warm_rejected: true,
            unchecked_after_checked_succeeded: buildUncheckedAfterChecked.status === 0,
          },
        },
      },
      comment_only: { default_on: commentOn.telemetry },
      private_body: { explicit_disable: privateOff.telemetry, default_on: privateOn.telemetry },
      public_interface: { explicit_disable: publicOff.telemetry, default_on: publicOn.telemetry },
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
      ambient_non_direct_cache_change_reuse: ambientReuse.telemetry,
      resolution_env_seed_change_fallback: resolutionFallback.telemetry,
      direct_dep_env_row_fallback: rowFallback.telemetry,
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
