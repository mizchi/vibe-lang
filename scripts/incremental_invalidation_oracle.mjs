#!/usr/bin/env node
// Bounded end-to-end observation bridge for Incremental.lean.
//
//   node scripts/incremental_invalidation_oracle.mjs <stage2.wasm>
//   node scripts/incremental_invalidation_oracle.mjs --check-oracle <tsv>
//
// This driver deliberately records the current conservative TypeDb behavior;
// it does not assert that production cache invalidation conforms to the Lean
// relation. The compiler sidecar has source identities plus an observation-
// only typed exported-interface fingerprint; no production cache key is read
// or changed here.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const telemetryKeys = [
  "modules_planned",
  "modules_rechecked",
  "modules_reused",
  "parse_operations",
  "modules_failed_or_blocked",
];
const expectedCorpus = new Map([
  ["no_op", { changed: [], invalidated: [] }],
  ["private_body_edit", { changed: ["library"], invalidated: ["library"] }],
  ["public_interface_edit", { changed: ["library"], invalidated: ["library", "app"] }],
  ["dependency_plan_edit", { changed: ["app"], invalidated: ["app"] }],
]);

function fail(message) {
  throw new Error(`incremental-invalidation-oracle: ${message}`);
}

/// Parse the versioned successful-check-only observation sidecar.
export function parseIncrementalInvalidationTrace(text, expectedNonce = undefined) {
  let trace;
  try {
    trace = JSON.parse(text);
  } catch (error) {
    fail(`invalid JSON (${error.message})`);
  }
  if (!trace || typeof trace !== "object" || Array.isArray(trace)) fail("expected object");
  if (trace.schema !== 2) fail(`unsupported schema ${JSON.stringify(trace.schema)}`);
  if (typeof trace.run_nonce !== "string" || trace.run_nonce.length === 0) fail("missing run_nonce");
  if (expectedNonce !== undefined && trace.run_nonce !== expectedNonce) fail("run_nonce mismatch (stale sidecar)");
  if (typeof trace.fingerprint_note !== "string" || !trace.fingerprint_note.includes("interface_fingerprint is an observation only")) {
    fail("missing observation-only interface-fingerprint declaration");
  }
  if (!Array.isArray(trace.modules) || trace.modules.length === 0) fail("missing modules");
  const paths = new Set();
  const decisions = new Map();
  for (const module of trace.modules) {
    if (!module || typeof module !== "object" || Array.isArray(module)) fail("invalid module row");
    if (typeof module.path !== "string" || module.path.length === 0 || paths.has(module.path)) fail("invalid or duplicate module path");
    paths.add(module.path);
    if (!Array.isArray(module.direct_dependencies) || !module.direct_dependencies.every((path) => typeof path === "string" && path.length > 0)) {
      fail(`invalid direct dependencies for ${module.path}`);
    }
    if (typeof module.source_fingerprint !== "string" || module.source_fingerprint.length === 0) fail(`missing source fingerprint for ${module.path}`);
    if (module.source_fingerprint_kind !== "compact_string_fingerprint(ingested_source)") fail(`dishonest fingerprint kind for ${module.path}`);
    if (typeof module.interface_fingerprint !== "string" || module.interface_fingerprint.length === 0) fail(`missing interface fingerprint for ${module.path}`);
    if (module.interface_fingerprint_kind !== "compact_string_fingerprint(vibe-module-interface:v1 canonical exported surface)") fail(`dishonest interface fingerprint kind for ${module.path}`);
    if (module.decision !== "rechecked" && module.decision !== "reused") fail(`invalid current decision for ${module.path}`);
    decisions.set(module.path, module.decision);
  }
  const telemetry = trace.aggregate_telemetry;
  if (!telemetry || typeof telemetry !== "object" || Array.isArray(telemetry) || telemetry.schema !== 1) fail("invalid aggregate telemetry");
  for (const key of telemetryKeys) {
    if (!Number.isSafeInteger(telemetry[key]) || telemetry[key] < 0) fail(`invalid aggregate telemetry ${key}`);
  }
  if (telemetry.modules_rechecked + telemetry.modules_reused + telemetry.modules_failed_or_blocked !== telemetry.modules_planned) {
    fail("aggregate telemetry does not partition planned modules");
  }
  if (telemetry.modules_failed_or_blocked !== 0) fail("successful trace recorded failed or blocked modules");
  if (telemetry.modules_planned !== trace.modules.length) fail("planned/module row count mismatch");
  if ([...decisions.values()].filter((decision) => decision === "rechecked").length !== telemetry.modules_rechecked) fail("rechecked decision count mismatch");
  if ([...decisions.values()].filter((decision) => decision === "reused").length !== telemetry.modules_reused) fail("reused decision count mismatch");
  return trace;
}

function moduleByName(trace, name) {
  const module = trace.modules.find((row) => basename(row.path) === `${name}.vibe`);
  if (!module) fail(`missing ${name}.vibe module row`);
  return module;
}

function decisionsByName(trace) {
  return Object.fromEntries(trace.modules.map((module) => [basename(module.path).replace(/\.vibe$/, ""), module.decision]));
}

function sourceOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.source_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.source_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

function interfaceOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.interface_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.interface_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

/// Executable observation-side shadow planner for the bounded Lean relation.
/// `source_fingerprint` is only an owner-change proxy here, not a normalized
/// implementation identity and not an artifact-input identity.
export function planObservedTypingInvalidation(before, after) {
  const beforeByPath = new Map(before.modules.map((module) => [module.path, module]));
  const afterByPath = new Map(after.modules.map((module) => [module.path, module]));
  const beforePaths = [...beforeByPath.keys()];
  const afterPaths = [...afterByPath.keys()];
  if (beforePaths.length !== afterPaths.length || beforePaths.some((path) => !afterByPath.has(path))) {
    fail("shadow planner requires an unchanged module-path universe");
  }
  const universe = new Set(beforePaths);
  for (const trace of [before, after]) {
    for (const module of trace.modules) {
      for (const dependency of module.direct_dependencies) {
        if (!universe.has(dependency)) fail(`shadow planner dependency outside module universe: ${dependency}`);
      }
    }
  }

  const interfaceChanged = new Set();
  const invalidated = new Set();
  for (const path of beforePaths) {
    const prior = beforeByPath.get(path);
    const next = afterByPath.get(path);
    if (prior.interface_fingerprint !== next.interface_fingerprint) {
      interfaceChanged.add(path);
      invalidated.add(path);
    } else if (prior.source_fingerprint !== next.source_fingerprint) {
      invalidated.add(path);
    }
    if (JSON.stringify(prior.direct_dependencies) !== JSON.stringify(next.direct_dependencies)) invalidated.add(path);
  }

  // Interface changes propagate to consumers through edges present before or
  // after the edit. Iteration to a fixpoint computes the bounded reverse closure.
  const interfaceClosure = new Set(interfaceChanged);
  let grew = true;
  while (grew) {
    grew = false;
    for (const consumer of beforePaths) {
      const dependencies = new Set([
        ...beforeByPath.get(consumer).direct_dependencies,
        ...afterByPath.get(consumer).direct_dependencies,
      ]);
      if ([...dependencies].some((dependency) => interfaceClosure.has(dependency)) && !interfaceClosure.has(consumer)) {
        interfaceClosure.add(consumer);
        invalidated.add(consumer);
        grew = true;
      }
    }
  }
  return afterPaths.filter((path) => invalidated.has(path));
}

/// Require every shadow-planned owner to have been rechecked. Extra rechecks
/// remain observable conservative over-invalidation rather than failures.
export function compareObservedInvalidation(before, after) {
  const planned = planObservedTypingInvalidation(before, after);
  const observed = after.modules.filter((module) => module.decision === "rechecked").map((module) => module.path);
  const observedSet = new Set(observed);
  const missing = planned.filter((path) => !observedSet.has(path));
  if (missing.length > 0) fail(`shadow planner required recheck missing for ${missing.join(",")}`);
  const plannedSet = new Set(planned);
  return { planned, observed, conservative_over_invalidation: observed.filter((path) => !plannedSet.has(path)) };
}

function ownerNames(paths) {
  return paths.map((path) => basename(path).replace(/\.vibe$/, ""));
}

function checkPlannerCase(name, before, after) {
  const expected = expectedCorpus.get(name);
  if (!expected) fail(`missing formal corpus case ${name}`);
  const comparison = compareObservedInvalidation(before, after);
  if (ownerNames(comparison.planned).join(",") !== expected.invalidated.join(",")) {
    fail(`shadow planner/formal corpus drift for ${name}`);
  }
  return {
    planned: ownerNames(comparison.planned),
    observed: ownerNames(comparison.observed),
    conservative_over_invalidation: ownerNames(comparison.conservative_over_invalidation),
  };
}

function checkOracleCorpus(path) {
  const lines = readFileSync(path, "utf8").trimEnd().split("\n");
  if (lines.shift() !== "case\tchanged_source_owners\tmodel_typing_invalidated") fail("unexpected corpus header");
  if (lines.length !== expectedCorpus.size) fail("unexpected corpus row count");
  for (const line of lines) {
    const [name, changed, invalidated] = line.split("\t");
    const expected = expectedCorpus.get(name);
    if (!expected) fail(`unknown corpus case ${name}`);
    if ((changed ? changed.split(",") : []).join(",") !== expected.changed.join(",")) fail(`changed-owner drift for ${name}`);
    if ((invalidated ? invalidated.split(",") : []).join(",") !== expected.invalidated.join(",")) fail(`invalidation drift for ${name}`);
  }
}

function run(stage2) {
  const runner = resolve(process.env.VIBE_RUNNER || join(root, "runtime/viberun/target/release/viberun"));
  const launcher = join(root, "runtime/vibe");
  if (![stage2, runner, launcher].every(existsSync)) fail("missing stage2 compiler, runner, or launcher");
  const work = mkdtempSync(join(tmpdir(), "vibe-incremental-invalidation-"));
  const project = join(work, "project");
  const cache = join(work, "cache");
  const traces = new Map();
  try {
    // A three-module chain makes private/public reverse-consumer behavior
    // observable without involving repository sources or an ambient cache.
    mkdirSync(project, { recursive: true });
    writeFileSync(join(project, "base.vibe"), "export fn base_value(x: Int) -> Int { x + 1 }\n");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport let library_value = base_value(40)\nfn private_offset() -> Int { 1 }\n");
    writeFileSync(join(project, "app.vibe"), "import ./library.vibe { library_value }\nfn main() -> Int { let _ = library_value\n0 }\n");
    const check = (name, { entry = "app.vibe", nonce = `scenario-${name}` } = {}) => {
      const tracePath = join(project, `${name}.trace.json`);
      const result = spawnSync(launcher, ["check", entry], {
        cwd: project,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_BUILD_CACHE_DIR: cache,
          VIBE_CLI_CWASM: "",
          VIBE_CLI_WASM: stage2,
          VIBE_HOME: join(work, "home"),
          VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: tracePath,
          VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: nonce,
          VIBE_PREOPEN_DIR: project,
          VIBE_RUNNER: runner,
        },
      });
      if (result.status !== 0) fail(`${name} check failed: ${(result.stderr || result.stdout).trim()}`);
      if (!existsSync(tracePath)) fail(`${name} sidecar missing after successful check`);
      const trace = parseIncrementalInvalidationTrace(readFileSync(tracePath, "utf8"), nonce);
      if (trace.modules.length !== 3) fail(`${name} did not report exactly three modules`);
      traces.set(name, trace);
      return trace;
    };
    const plannerCases = {};
    const baseline = check("cold");
    if (baseline.aggregate_telemetry.modules_rechecked !== 3) fail("cold run did not recheck all modules");
    const noOp = check("no_op");
    if (sourceOwnersChanged(baseline, noOp).length !== 0) fail("no-op changed a source identity");
    if (interfaceOwnersChanged(baseline, noOp).length !== 0) fail("no-op changed an interface identity");
    if (noOp.aggregate_telemetry.modules_rechecked !== 0) fail("no-op was not reused by the current cache");
    plannerCases.no_op = checkPlannerCase("no_op", baseline, noOp);

    writeFileSync(join(project, "library.vibe"), "// observation-only comment\nimport ./base.vibe { base_value }\nexport let library_value = base_value(40)\nfn private_offset() -> Int { 1 }\n");
    const commentEdit = check("comment_edit");
    if (sourceOwnersChanged(noOp, commentEdit).join(",") !== "library") fail("comment edit source delta drift");
    if (interfaceOwnersChanged(noOp, commentEdit).length !== 0) fail("comment edit changed an interface identity");

    writeFileSync(join(project, "library.vibe"), "// observation-only comment\nimport ./base.vibe { base_value }\nexport let library_value = base_value(40)\nfn private_offset() -> Int { 2 }\n");
    const privateEdit = check("private_body_edit");
    if (sourceOwnersChanged(commentEdit, privateEdit).join(",") !== "library") fail("private edit source delta drift");
    if (interfaceOwnersChanged(commentEdit, privateEdit).length !== 0) fail("private edit changed an interface identity");
    if (JSON.stringify(decisionsByName(privateEdit)) !== JSON.stringify({ base: "reused", library: "rechecked", app: "rechecked" })) {
      fail("private edit current decision drift");
    }
    plannerCases.private_body_edit = checkPlannerCase("private_body_edit", commentEdit, privateEdit);

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicEdit = check("public_interface_edit");
    if (sourceOwnersChanged(privateEdit, publicEdit).join(",") !== "library") fail("public edit source delta drift");
    if (interfaceOwnersChanged(privateEdit, publicEdit).join(",") !== "library") fail("public inferred type edit did not change the exported interface identity");
    if (JSON.stringify(decisionsByName(publicEdit)) !== JSON.stringify({ base: "reused", library: "rechecked", app: "rechecked" })) {
      fail("public edit current decision drift");
    }
    plannerCases.public_interface_edit = checkPlannerCase("public_interface_edit", privateEdit, publicEdit);

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct PublicShape { value: Int }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicTypeAdd = check("public_type_add");
    if (interfaceOwnersChanged(publicEdit, publicTypeAdd).join(",") !== "library") fail("exported type addition did not change the interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct PublicShape { value: String }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicTypeLayout = check("public_type_layout_edit");
    if (interfaceOwnersChanged(publicTypeAdd, publicTypeLayout).join(",") !== "library") fail("exported type layout edit did not change the interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[T](T) -> T }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitGenericT = check("trait_generic_t");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U](U) -> U }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitGenericU = check("trait_generic_u");
    if (interfaceOwnersChanged(traitGenericT, traitGenericU).length !== 0) fail("alpha-equivalent trait method generic rename changed interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U: Show](U) -> U }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitBoundShow = check("trait_bound_show");
    if (interfaceOwnersChanged(traitGenericU, traitBoundShow).join(",") !== "library") fail("trait method generic bound addition did not change interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U: Eq](U) -> U }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitBoundEq = check("trait_bound_eq");
    if (interfaceOwnersChanged(traitBoundShow, traitBoundEq).join(",") !== "library") fail("trait method generic bound edit did not change interface identity");

    writeFileSync(join(project, "app.vibe"), "import ./base.vibe { base_value }\nimport ./library.vibe { library_value }\nfn main() -> Int { let _ = library_value\nbase_value(0) }\n");
    const planEdit = check("dependency_plan_edit");
    if (sourceOwnersChanged(traitBoundEq, planEdit).join(",") !== "app") fail("dependency-plan edit source delta drift");
    if (JSON.stringify(decisionsByName(planEdit)) !== JSON.stringify({ base: "reused", library: "reused", app: "rechecked" })) {
      fail("dependency-plan edit current decision drift");
    }
    const appDependencies = moduleByName(planEdit, "app").direct_dependencies.map((path) => basename(path));
    if (appDependencies.join(",") !== "base.vibe,library.vibe") fail("dependency-plan trace did not record the added base import in declaration order");
    plannerCases.dependency_plan_edit = checkPlannerCase("dependency_plan_edit", traitBoundEq, planEdit);

    // Integration regressions for the renderer: JSON requires every U+0000–
    // U+001F control character to be escaped, and POSIX paths may contain TAB.
    check("control_nonce", { nonce: "scenario-control-\b-nonce" });
    const tabEntry = "tab\tapp.vibe";
    writeFileSync(join(project, tabEntry), "import ./library.vibe { library_value }\nfn main() -> Int { let _ = library_value\n0 }\n");
    const tabTrace = check("tab_path", { entry: tabEntry });
    if (!tabTrace.modules.some((module) => basename(module.path) === tabEntry)) fail("TAB path was not preserved in the structured trace");

    // The model says private body edit need only invalidate library typing;
    // report (rather than fail on) the current implementation's additional
    // rechecks. This is the intended conservative-over-invalidation record.
    const currentPrivateRechecks = privateEdit.modules.filter((module) => module.decision === "rechecked").map((module) => module.path.replace(/\.vibe$/, ""));
    console.log(JSON.stringify({
      schema: 2,
      scenario: "three-module-incremental-invalidation",
      model_private_body_typing_invalidated: ["library"],
      current_private_body_rechecked: currentPrivateRechecks,
      conservative_over_invalidation: currentPrivateRechecks.filter((name) => name !== "library"),
      planner_cases: plannerCases,
      cases: [...traces.keys()],
    }));
  } finally {
    if (process.env.VIBE_INCREMENTAL_ORACLE_KEEP_TMP === "1") console.error(`incremental-invalidation-oracle: kept ${work}`);
    else rmSync(work, { recursive: true, force: true });
  }
}


if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === "--check-oracle") {
    if (!process.argv[3]) fail("--check-oracle needs a corpus path");
    checkOracleCorpus(resolve(process.cwd(), process.argv[3]));
  } else {
    if (!process.argv[2]) fail("usage: incremental_invalidation_oracle.mjs <stage2.wasm>");
    const stage2 = isAbsolute(process.argv[2]) ? process.argv[2] : resolve(process.cwd(), process.argv[2]);
    run(stage2);
  }
}
