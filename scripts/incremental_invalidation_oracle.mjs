#!/usr/bin/env node
// Bounded end-to-end observation bridge for Incremental.lean.
//
//   node scripts/incremental_invalidation_oracle.mjs <stage2.wasm>
//   node scripts/incremental_invalidation_oracle.mjs --check-oracle <tsv>
//
// This driver deliberately records the current conservative TypeDb behavior;
// it does not assert that production cache invalidation conforms to the Lean
// relation. The compiler sidecar has source ingestion telemetry plus
// observation-only canonical token-stream implementation and typed
// exported-interface fingerprints; none is read by or incorporated into a
// production cache key here. The normal compiler-source fingerprint still
// invalidates compiler artifacts after any compiler source change.
//
// #1548: VIBE_SHADOW_DECISION_DIFF_OUT=<path> additionally publishes the
// per-case shadow planner vs current compiler decision diff as a versioned
// JSON artifact — only after every case succeeded (a failed run deletes the
// requested path and publishes nothing). CI uploads it so the conservative
// over-invalidation residual stays visible per run.

import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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
const fingerprintNote = "source_fingerprint is ingestion telemetry; implementation_fingerprint remains the provisional canonical token-stream identity; interface_fingerprint, checked_env_fingerprint, and persistent_type_env_transport_fingerprint are observation only; persistent_type_env_transport_fingerprint is TypeEnv transport only, not CheckedProgram, typed IR, exported interface, cache key, or reuse decision; none is a production cache key";
const sourceFingerprintKind = "compact_string_fingerprint(ingested_source)";
const implementationFingerprintKind = "compact_string_fingerprint(vibe-module-token-stream:v1 length_delimited(token_kind,source_lexeme))";
const interfaceFingerprintKind = "compact_string_fingerprint(vibe-module-interface:v4 canonical exported surface including kinded applications)";
const checkedEnvFingerprintKind = "compact_string_fingerprint(vibe-module-checked-env:v3 canonical effective TypeEnv value bindings including kinded applications)";
const persistentTypeEnvTransportFingerprintKind = "compact_string_fingerprint(persistent_type_env_cache_text:v9 complete TypeEnv transport only; not CheckedProgram, typed IR, exported interface, cache key, or reuse decision)";

const expectedCorpus = new Map([
  ["no_op", { sourceChanged: [], implementationChanged: [], invalidated: [] }],
  ["comment_only_edit", { sourceChanged: ["library"], implementationChanged: [], invalidated: [] }],
  ["private_body_edit", { sourceChanged: ["library"], implementationChanged: ["library"], invalidated: ["library"] }],
  ["public_interface_edit", { sourceChanged: ["library"], implementationChanged: ["library"], invalidated: ["library", "app"] }],
  ["dependency_plan_edit", { sourceChanged: ["app"], implementationChanged: ["app"], invalidated: ["app"] }],
]);

function fail(message) {
  throw new Error(`incremental-invalidation-oracle: ${message}`);
}

function exactKeys(value, keys, label) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  const missing = expected.find((key) => !Object.hasOwn(value, key));
  if (missing) fail(`missing ${label} ${missing}`);
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail(`unexpected ${label} keys`);
  }
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
  exactKeys(trace, ["schema", "run_nonce", "fingerprint_note", "modules", "aggregate_telemetry"], "trace");
  if (trace.schema !== 6) fail(`unsupported schema ${JSON.stringify(trace.schema)}`);
  if (typeof trace.run_nonce !== "string" || trace.run_nonce.length === 0) fail("missing run_nonce");
  if (expectedNonce !== undefined && trace.run_nonce !== expectedNonce) fail("run_nonce mismatch (stale sidecar)");
  if (trace.fingerprint_note !== fingerprintNote) fail("dishonest fingerprint_note");
  if (!Array.isArray(trace.modules) || trace.modules.length === 0) fail("missing modules");
  const paths = new Set();
  const decisions = new Map();
  for (const module of trace.modules) {
    if (!module || typeof module !== "object" || Array.isArray(module)) fail("invalid module row");
    exactKeys(module, [
      "path", "direct_dependencies", "source_fingerprint", "source_fingerprint_kind",
      "implementation_fingerprint", "implementation_fingerprint_kind", "interface_fingerprint",
      "interface_fingerprint_kind", "checked_env_fingerprint", "checked_env_fingerprint_kind",
      "persistent_type_env_transport_fingerprint", "persistent_type_env_transport_fingerprint_kind", "decision",
    ], `module row`);
    if (typeof module.path !== "string" || module.path.length === 0 || paths.has(module.path)) fail("invalid or duplicate module path");
    paths.add(module.path);
    if (!Array.isArray(module.direct_dependencies) || !module.direct_dependencies.every((path) => typeof path === "string" && path.length > 0)) {
      fail(`invalid direct dependencies for ${module.path}`);
    }
    if (typeof module.source_fingerprint !== "string" || module.source_fingerprint.length === 0) fail(`missing source fingerprint for ${module.path}`);
    if (module.source_fingerprint_kind !== sourceFingerprintKind) fail(`dishonest source fingerprint kind for ${module.path}`);
    if (typeof module.implementation_fingerprint !== "string" || module.implementation_fingerprint.length === 0) fail(`missing implementation fingerprint for ${module.path}`);
    if (module.implementation_fingerprint_kind !== implementationFingerprintKind) fail(`dishonest implementation fingerprint kind for ${module.path}`);
    if (typeof module.interface_fingerprint !== "string" || module.interface_fingerprint.length === 0) fail(`missing interface fingerprint for ${module.path}`);
    if (module.interface_fingerprint_kind !== interfaceFingerprintKind) fail(`dishonest interface fingerprint kind for ${module.path}`);
    if (typeof module.checked_env_fingerprint !== "string" || module.checked_env_fingerprint.length === 0) fail(`missing checked environment fingerprint for ${module.path}`);
    if (module.checked_env_fingerprint_kind !== checkedEnvFingerprintKind) fail(`dishonest checked environment fingerprint kind for ${module.path}`);
    if (typeof module.persistent_type_env_transport_fingerprint !== "string" || module.persistent_type_env_transport_fingerprint.length === 0) fail(`missing persistent TypeEnv transport fingerprint for ${module.path}`);
    if (module.persistent_type_env_transport_fingerprint_kind !== persistentTypeEnvTransportFingerprintKind) fail(`dishonest persistent TypeEnv transport fingerprint kind for ${module.path}`);
    if (module.decision !== "rechecked" && module.decision !== "reused") fail(`invalid current decision for ${module.path}`);
    decisions.set(module.path, module.decision);
  }
  // Paths must be collected before validating edges: validating in the row
  // loop would incorrectly reject a dependency declared later in trace order.
  for (const module of trace.modules) {
    for (const dependency of module.direct_dependencies) {
      if (!paths.has(dependency)) fail(`direct dependency outside trace module universe for ${module.path}: ${dependency}`);
    }
  }
  const telemetry = trace.aggregate_telemetry;
  if (!telemetry || typeof telemetry !== "object" || Array.isArray(telemetry)) fail("invalid aggregate telemetry");
  exactKeys(telemetry, ["schema", ...telemetryKeys], "aggregate telemetry");
  if (telemetry.schema !== 1) fail("invalid aggregate telemetry");
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

/// Compare two successful, already-parsed observations while deliberately
/// excluding the per-run freshness nonce. This is intentionally stricter than
/// clean-snapshot parity: decisions and every versioned observation field are
/// semantic evidence for the same check, so any drift is a failure.
export function compareSuccessfulIncrementalInvalidationTraces(expected, actual) {
  const mismatch = (context, expectedValue, actualValue) => {
    fail(`semantic trace mismatch at ${context}: expected ${JSON.stringify(expectedValue)}, got ${JSON.stringify(actualValue)}`);
  };
  const compareField = (context, left, right) => {
    if (left !== right) mismatch(context, left, right);
  };
  const compareArray = (context, left, right) => {
    if (left.length !== right.length) mismatch(`${context}.length`, left.length, right.length);
    for (let index = 0; index < left.length; index += 1) compareField(`${context}[${index}]`, left[index], right[index]);
  };

  compareField("schema", expected.schema, actual.schema);
  compareField("fingerprint_note", expected.fingerprint_note, actual.fingerprint_note);
  if (expected.modules.length !== actual.modules.length) mismatch("modules.length", expected.modules.length, actual.modules.length);
  const moduleFields = [
    "path", "source_fingerprint", "source_fingerprint_kind",
    "implementation_fingerprint", "implementation_fingerprint_kind", "interface_fingerprint",
    "interface_fingerprint_kind", "checked_env_fingerprint", "checked_env_fingerprint_kind",
    "persistent_type_env_transport_fingerprint", "persistent_type_env_transport_fingerprint_kind", "decision",
  ];
  for (let index = 0; index < expected.modules.length; index += 1) {
    const left = expected.modules[index];
    const right = actual.modules[index];
    // Compare positional paths first, so a module-order drift has stable,
    // useful context rather than being misreported as a later field drift.
    compareField(`modules[${index}].path`, left.path, right.path);
    const context = `modules[${index}](${left.path})`;
    compareArray(`${context}.direct_dependencies`, left.direct_dependencies, right.direct_dependencies);
    for (const field of moduleFields.slice(1)) compareField(`${context}.${field}`, left[field], right[field]);
  }
  for (const key of ["schema", ...telemetryKeys]) {
    compareField(`aggregate_telemetry.${key}`, expected.aggregate_telemetry[key], actual.aggregate_telemetry[key]);
  }
}

function moduleByName(trace, name) {
  const modules = trace.modules.filter((row) => basename(row.path) === `${name}.vibe`);
  if (modules.length === 0) fail(`missing ${name}.vibe module row`);
  if (modules.length !== 1) fail(`ambiguous ${name}.vibe module row`);
  return modules[0];
}

function decisionsByName(trace) {
  return Object.fromEntries(trace.modules.map((module) => [basename(module.path).replace(/\.vibe$/, ""), module.decision]));
}

function sourceOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.source_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.source_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

function implementationOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.implementation_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.implementation_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

function interfaceOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.interface_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.interface_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

function checkedEnvOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.checked_env_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.checked_env_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

function persistentTypeEnvTransportOwnersChanged(before, after) {
  const prior = new Map(before.modules.map((module) => [module.path, module.persistent_type_env_transport_fingerprint]));
  return after.modules.filter((module) => prior.get(module.path) !== module.persistent_type_env_transport_fingerprint).map((module) => basename(module.path).replace(/\.vibe$/, ""));
}

/// Clean snapshots must reproduce every semantic observation for the same
/// sources. Decisions intentionally remain excluded: clean runs necessarily
/// recheck while a warm TypeDb may reuse.
function compareCleanSnapshotObservations(name, warm, clean) {
  const cleanByPath = new Map(clean.modules.map((module) => [module.path, module]));
  if (warm.modules.length !== clean.modules.length) fail(`${name} clean/warm module count mismatch`);
  for (const warmModule of warm.modules) {
    const cleanModule = cleanByPath.get(warmModule.path);
    if (!cleanModule) fail(`${name} clean snapshot missing module ${warmModule.path}`);
    for (const field of ["source_fingerprint", "implementation_fingerprint", "interface_fingerprint", "checked_env_fingerprint", "persistent_type_env_transport_fingerprint"]) {
      if (warmModule[field] !== cleanModule[field]) fail(`${name} clean/warm ${field} mismatch for ${warmModule.path}`);
    }
  }
}

/// Executable observation-side shadow planner for the bounded Lean relation.
/// Source identity is ingestion telemetry only. Canonical token-stream
/// implementation identity invalidates the owner, while interface changes reverse-close.
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
    } else if (prior.implementation_fingerprint !== next.implementation_fingerprint) {
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

const shadowDecisionDiffSchema = "incremental_shadow_decision_diff";
const shadowDecisionDiffScopeNote = "shadow planner decisions derive from observation-only fingerprints and are not production cache keys or reuse decisions; conservative over-invalidation is the permitted visible residual; a missing required recheck fails the oracle before this artifact is published, so no published row records one";

/// Diff one bounded edit case: the shadow planner's decision against the
/// current TypeDb decision, per module in trace order. A missing required
/// recheck is a failure, never a published row (Roadmap invariants).
export function buildShadowDecisionDiffCase(name, before, after) {
  const planned = new Set(planObservedTypingInvalidation(before, after));
  const modules = after.modules.map((module) => {
    const shadow_decision = planned.has(module.path) ? "recheck_required" : "typing_reusable";
    const compiler_decision = module.decision;
    let classification;
    if (shadow_decision === "recheck_required" && compiler_decision === "rechecked") classification = "agreement_recheck";
    else if (shadow_decision === "typing_reusable" && compiler_decision === "reused") classification = "agreement_reuse";
    else if (shadow_decision === "typing_reusable" && compiler_decision === "rechecked") classification = "conservative_over_invalidation";
    else fail(`shadow decision diff for ${name} would publish a missing required recheck for ${module.path}`);
    return { path: module.path, shadow_decision, compiler_decision, classification };
  });
  return {
    case: name,
    modules,
    conservative_over_invalidation: modules
      .filter((row) => row.classification === "conservative_over_invalidation")
      .map((row) => row.path),
  };
}

/// Aggregate the per-case diffs into the versioned CI artifact (#1548). The
/// artifact records current conservative behavior; it is not a reuse rule.
export function buildShadowDecisionDiffArtifact(cases, { scenario, stage2_sha256 }) {
  const totals = { agreement_recheck: 0, agreement_reuse: 0, conservative_over_invalidation: 0 };
  for (const diffCase of cases) {
    for (const row of diffCase.modules) totals[row.classification] += 1;
  }
  return {
    schema: shadowDecisionDiffSchema,
    version: 1,
    scenario,
    stage2_sha256,
    scope_note: shadowDecisionDiffScopeNote,
    cases,
    totals,
  };
}

/// Strict parse of the published diff artifact. Consumers must reject rather
/// than repair: unknown fields, inconsistent classifications, and total drift
/// all fail so a torn or hand-edited artifact cannot pass as evidence.
export function parseShadowDecisionDiffArtifact(text) {
  let artifact;
  try {
    artifact = JSON.parse(text);
  } catch (error) {
    fail(`shadow decision diff: invalid JSON (${error.message})`);
  }
  if (!artifact || typeof artifact !== "object" || Array.isArray(artifact)) fail("shadow decision diff: expected object");
  exactKeys(artifact, ["schema", "version", "scenario", "stage2_sha256", "scope_note", "cases", "totals"], "shadow decision diff");
  if (artifact.schema !== shadowDecisionDiffSchema) fail(`shadow decision diff: unsupported schema ${JSON.stringify(artifact.schema)}`);
  if (artifact.version !== 1) fail(`shadow decision diff: unsupported version ${JSON.stringify(artifact.version)}`);
  if (typeof artifact.scenario !== "string" || artifact.scenario.length === 0) fail("shadow decision diff: missing scenario");
  if (typeof artifact.stage2_sha256 !== "string" || !/^[0-9a-f]{64}$/.test(artifact.stage2_sha256)) fail("shadow decision diff: invalid stage2_sha256");
  if (artifact.scope_note !== shadowDecisionDiffScopeNote) fail("shadow decision diff: dishonest scope_note");
  if (!Array.isArray(artifact.cases) || artifact.cases.length === 0) fail("shadow decision diff: missing cases");
  const totals = { agreement_recheck: 0, agreement_reuse: 0, conservative_over_invalidation: 0 };
  const caseNames = new Set();
  for (const diffCase of artifact.cases) {
    if (!diffCase || typeof diffCase !== "object" || Array.isArray(diffCase)) fail("shadow decision diff: invalid case row");
    exactKeys(diffCase, ["case", "modules", "conservative_over_invalidation"], "shadow decision diff case");
    if (typeof diffCase.case !== "string" || diffCase.case.length === 0 || caseNames.has(diffCase.case)) fail("shadow decision diff: invalid or duplicate case name");
    caseNames.add(diffCase.case);
    if (!Array.isArray(diffCase.modules) || diffCase.modules.length === 0) fail(`shadow decision diff: missing modules for ${diffCase.case}`);
    const paths = new Set();
    const residual = [];
    for (const row of diffCase.modules) {
      if (!row || typeof row !== "object" || Array.isArray(row)) fail(`shadow decision diff: invalid module row in ${diffCase.case}`);
      exactKeys(row, ["path", "shadow_decision", "compiler_decision", "classification"], "shadow decision diff module row");
      if (typeof row.path !== "string" || row.path.length === 0 || paths.has(row.path)) fail(`shadow decision diff: invalid or duplicate module path in ${diffCase.case}`);
      paths.add(row.path);
      const expectedClassification =
        row.shadow_decision === "recheck_required" && row.compiler_decision === "rechecked" ? "agreement_recheck"
        : row.shadow_decision === "typing_reusable" && row.compiler_decision === "reused" ? "agreement_reuse"
        : row.shadow_decision === "typing_reusable" && row.compiler_decision === "rechecked" ? "conservative_over_invalidation"
        : undefined;
      if (expectedClassification === undefined) fail(`shadow decision diff: published missing required recheck for ${row.path} in ${diffCase.case}`);
      if (row.classification !== expectedClassification) fail(`shadow decision diff: classification inconsistent with decisions for ${row.path} in ${diffCase.case}`);
      totals[row.classification] += 1;
      if (row.classification === "conservative_over_invalidation") residual.push(row.path);
    }
    if (JSON.stringify(diffCase.conservative_over_invalidation) !== JSON.stringify(residual)) {
      fail(`shadow decision diff: residual summary drift for ${diffCase.case}`);
    }
  }
  const actualTotals = artifact.totals;
  if (!actualTotals || typeof actualTotals !== "object" || Array.isArray(actualTotals)) fail("shadow decision diff: invalid totals");
  exactKeys(actualTotals, Object.keys(totals), "shadow decision diff totals");
  for (const [key, value] of Object.entries(totals)) {
    if (actualTotals[key] !== value) fail(`shadow decision diff: totals drift for ${key}`);
  }
  return artifact;
}

function ownerNames(paths) {
  return paths.map((path) => basename(path).replace(/\.vibe$/, ""));
}

/// Classify the bounded library-body edit without promoting any observation to
/// production policy. The consumer must name exactly the edited dependency in
/// both snapshots: extra, missing, reordered, or changed edges fail closed.
/// TypeEnv-v9 transport state is reported independently from interface-v4.
export function classifyPrivateDependencyEditExternallyUnchanged(before, after, dependencyName, consumerName) {
  const beforeDependency = moduleByName(before, dependencyName);
  const afterDependency = moduleByName(after, dependencyName);
  const beforeConsumer = moduleByName(before, consumerName);
  const afterConsumer = moduleByName(after, consumerName);
  if (beforeDependency.path !== afterDependency.path) fail("private dependency path changed across observations");
  if (beforeConsumer.path !== afterConsumer.path) fail("private dependency consumer path changed across observations");

  const expectedDependencies = [beforeDependency.path];
  for (const [snapshot, consumer] of [["before", beforeConsumer], ["after", afterConsumer]]) {
    if (JSON.stringify(consumer.direct_dependencies) !== JSON.stringify(expectedDependencies)) {
      fail(`private dependency ${snapshot} direct relation was not exactly ${consumerName} -> ${dependencyName}`);
    }
  }
  const requireIdentity = (snapshot, module, field) => {
    if (typeof module[field] !== "string" || module[field].length === 0) {
      fail(`private dependency classification missing ${snapshot} ${field}`);
    }
  };
  for (const [snapshot, dependency] of [["before dependency", beforeDependency], ["after dependency", afterDependency]]) {
    for (const field of ["source_fingerprint", "implementation_fingerprint", "interface_fingerprint", "persistent_type_env_transport_fingerprint"]) {
      requireIdentity(snapshot, dependency, field);
    }
  }
  if (beforeDependency.source_fingerprint === afterDependency.source_fingerprint) {
    fail("private dependency edit did not change dependency source identity");
  }
  if (beforeDependency.implementation_fingerprint === afterDependency.implementation_fingerprint) {
    fail("private dependency edit did not change dependency implementation identity");
  }
  if (beforeDependency.interface_fingerprint !== afterDependency.interface_fingerprint) {
    fail("private dependency edit changed dependency interface-v4 identity");
  }

  const consumerIdentityFields = [
    "source_fingerprint",
    "implementation_fingerprint",
    "interface_fingerprint",
    "checked_env_fingerprint",
    "persistent_type_env_transport_fingerprint",
  ];
  for (const field of consumerIdentityFields) {
    requireIdentity("before consumer", beforeConsumer, field);
    requireIdentity("after consumer", afterConsumer, field);
    if (beforeConsumer[field] !== afterConsumer[field]) fail(`private dependency edit changed consumer own ${field}`);
  }
  if (afterConsumer.decision !== "rechecked") {
    fail("private dependency edit consumer is no longer conservatively rechecked");
  }

  return {
    classification: "private_dependency_edit_externally_unchanged",
    dependency: dependencyName,
    consumer: consumerName,
    direct_dependency_relation: {
      before: [`${consumerName}->${dependencyName}`],
      after: [`${consumerName}->${dependencyName}`],
    },
    dependency_identity: {
      source: "changed",
      implementation_token_stream_v1: "changed",
      interface_v3: "unchanged",
    },
    dependency_type_env_transport_v5: beforeDependency.persistent_type_env_transport_fingerprint === afterDependency.persistent_type_env_transport_fingerprint
      ? "unchanged"
      : "changed",
    consumer_own_identities: Object.fromEntries(consumerIdentityFields.map((field) => [field, "unchanged"])),
    current_consumer_decision: "conservative_rechecked",
  };
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

function corpusOwners(cell) {
  return !cell || cell === "-" ? [] : cell.split(",");
}

function checkOracleCorpus(path) {
  const lines = readFileSync(path, "utf8").trimEnd().split("\n");
  if (lines.shift() !== "case\tchanged_source_owners\tchanged_implementation_owners\tmodel_typing_invalidated") fail("unexpected corpus header");
  if (lines.length !== expectedCorpus.size) fail("unexpected corpus row count");
  for (const line of lines) {
    const [name, sourceChanged, implementationChanged, invalidated] = line.split("\t");
    const expected = expectedCorpus.get(name);
    if (!expected) fail(`unknown corpus case ${name}`);
    if (corpusOwners(sourceChanged).join(",") !== expected.sourceChanged.join(",")) fail(`source-owner drift for ${name}`);
    if (corpusOwners(implementationChanged).join(",") !== expected.implementationChanged.join(",")) fail(`implementation-owner drift for ${name}`);
    if (corpusOwners(invalidated).join(",") !== expected.invalidated.join(",")) fail(`invalidation drift for ${name}`);
  }
}

function run(stage2) {
  const invoke = join(root, "scripts/run_wasm_vibe_host_runner.sh");
  if (![stage2, invoke].every(existsSync)) fail("missing stage2 compiler or node host runner");
  // #1548: delete a previously requested diff artifact before doing any work,
  // so a failed run can never leave an old diff to be mistaken for this run.
  const diffOut = process.env.VIBE_SHADOW_DECISION_DIFF_OUT
    ? resolve(process.cwd(), process.env.VIBE_SHADOW_DECISION_DIFF_OUT)
    : "";
  if (diffOut) rmSync(diffOut, { force: true });
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
    const runSnapshot = (name, { entry, nonce, cacheDir, suffix }) => {
      const traceName = `${name}.${suffix}.trace.json`;
      const tracePath = join(project, traceName);
      const checkOut = `${name}.${suffix}.check.out`;
      const result = spawnSync("bash", [invoke, "--invoke", "cli_main", stage2, entry, checkOut], {
        cwd: project,
        encoding: "utf8",
        env: {
          ...process.env,
          VIBE_BUILD_CACHE_DIR: cacheDir,
          VIBE_CHECK_ONLY: "1",
          VIBE_IMPORT_ABI: "raw",
          VIBE_HOME: join(work, `home-${suffix}`),
          VIBE_INCREMENTAL_INVALIDATION_TRACE_OUT: traceName,
          VIBE_INCREMENTAL_INVALIDATION_TRACE_NONCE: nonce,
          VIBE_PREOPEN_DIR: project,
        },
      });
      if (result.status !== 0 || !existsSync(join(project, checkOut))) fail(`${name} ${suffix} check failed: ${(result.stderr || result.stdout).trim()}`);
      if (!existsSync(tracePath)) fail(`${name} ${suffix} sidecar missing after successful check`);
      return parseIncrementalInvalidationTrace(readFileSync(tracePath, "utf8"), nonce);
    };
    const check = (name, { entry = "app.vibe", nonce = `scenario-${name}` } = {}) => {
      const trace = runSnapshot(name, { entry, nonce, cacheDir: cache, suffix: "warm" });
      const clean = runSnapshot(name, {
        entry,
        nonce: `clean-${nonce}`,
        cacheDir: join(work, `clean-cache-${name}`),
        suffix: "clean",
      });
      if (trace.modules.length !== 3) fail(`${name} did not report exactly three modules`);
      compareCleanSnapshotObservations(name, trace, clean);
      traces.set(name, trace);
      return trace;
    };
    const plannerCases = {};
    const shadowDiffCases = [];
    const runPlannerCase = (name, before, after) => {
      plannerCases[name] = checkPlannerCase(name, before, after);
      shadowDiffCases.push(buildShadowDecisionDiffCase(name, before, after));
    };
    const baseline = check("cold");
    if (baseline.aggregate_telemetry.modules_rechecked !== 3) fail("cold run did not recheck all modules");
    const noOp = check("no_op");
    if (sourceOwnersChanged(baseline, noOp).length !== 0) fail("no-op changed a source identity");
    if (implementationOwnersChanged(baseline, noOp).length !== 0) fail("no-op changed an implementation identity");
    if (interfaceOwnersChanged(baseline, noOp).length !== 0) fail("no-op changed an interface identity");
    if (noOp.aggregate_telemetry.modules_rechecked !== 0) fail("no-op was not reused by the current cache");
    runPlannerCase("no_op", baseline, noOp);

    writeFileSync(join(project, "library.vibe"), "// observation-only comment\nimport ./base.vibe { base_value }\nexport let library_value = base_value(40)\nfn private_offset() -> Int { 1 }\n");
    const commentEdit = check("comment_edit");
    if (sourceOwnersChanged(noOp, commentEdit).join(",") !== "library") fail("comment edit source delta drift");
    if (implementationOwnersChanged(noOp, commentEdit).length !== 0) fail("comment edit changed token-stream implementation identity");
    if (interfaceOwnersChanged(noOp, commentEdit).length !== 0) fail("comment edit changed an interface identity");
    runPlannerCase("comment_only_edit", noOp, commentEdit);

    writeFileSync(join(project, "library.vibe"), "// observation-only comment\nimport ./base.vibe { base_value }\nexport let library_value = base_value(40)\nfn private_offset() -> Int { 2 }\n");
    const privateEdit = check("private_body_edit");
    if (sourceOwnersChanged(commentEdit, privateEdit).join(",") !== "library") fail("private edit source delta drift");
    if (implementationOwnersChanged(commentEdit, privateEdit).join(",") !== "library") fail("private edit implementation delta drift");
    if (interfaceOwnersChanged(commentEdit, privateEdit).length !== 0) fail("private edit changed an interface identity");
    if (moduleByName(commentEdit, "library").checked_env_fingerprint !== moduleByName(privateEdit, "library").checked_env_fingerprint) {
      fail("private body token identity changed the checked environment identity");
    }
    if (JSON.stringify(decisionsByName(privateEdit)) !== JSON.stringify({ base: "reused", library: "rechecked", app: "rechecked" })) {
      fail("private edit current decision drift");
    }
    const privateDependencyClassification = classifyPrivateDependencyEditExternallyUnchanged(
      commentEdit,
      privateEdit,
      "library",
      "app",
    );
    runPlannerCase("private_body_edit", commentEdit, privateEdit);

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicEdit = check("public_interface_edit");
    if (sourceOwnersChanged(privateEdit, publicEdit).join(",") !== "library") fail("public edit source delta drift");
    if (implementationOwnersChanged(privateEdit, publicEdit).join(",") !== "library") fail("public edit implementation delta drift");
    if (interfaceOwnersChanged(privateEdit, publicEdit).join(",") !== "library") fail("public inferred type edit did not change the exported interface identity");
    if (JSON.stringify(decisionsByName(publicEdit)) !== JSON.stringify({ base: "reused", library: "rechecked", app: "rechecked" })) {
      fail("public edit current decision drift");
    }
    runPlannerCase("public_interface_edit", privateEdit, publicEdit);

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Logger { Info(String) -> Unit }\nexport effect Audit { Record(String) -> Unit }\nexport fn announce(message: String) -> Unit with Logger { let _ = message\n() }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicFunctionLogger = check("public_function_logger");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Logger { Info(String) -> Unit }\nexport effect Audit { Record(String) -> Unit }\nexport fn announce(message: String) -> Unit with Audit { let _ = message\n() }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicFunctionAudit = check("public_function_audit");
    if (interfaceOwnersChanged(publicFunctionLogger, publicFunctionAudit).join(",") !== "library") fail("exported function effect edit did not change the interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport type PublicAlias = Int\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicAliasInt = check("public_alias_int");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport type PublicAlias = String\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicAliasString = check("public_alias_string");
    if (interfaceOwnersChanged(publicAliasInt, publicAliasString).join(",") !== "library") fail("exported type alias edit did not change the interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct PublicShape { value: Int }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicTypeAdd = check("public_type_add");
    if (interfaceOwnersChanged(publicEdit, publicTypeAdd).join(",") !== "library") fail("exported type addition did not change the interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct PublicShape { value: String }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicTypeLayout = check("public_type_layout_edit");
    if (interfaceOwnersChanged(publicTypeAdd, publicTypeLayout).join(",") !== "library") fail("exported type layout edit did not change the interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct DerivedShape { value: Int } derive(Eq)\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicDeriveEq = check("public_derive_eq");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct DerivedShape { value: Int } derive(Eq, Show)\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const publicDeriveShow = check("public_derive_show");
    if (interfaceOwnersChanged(publicDeriveEq, publicDeriveShow).join(",") !== "library") fail("exported type derive edit did not change the interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport fn generic_identity[T](value: T) -> T { value }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const genericValueT = check("generic_value_t");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport fn generic_identity[U](value: U) -> U { value }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const genericValueU = check("generic_value_u");
    if (implementationOwnersChanged(genericValueT, genericValueU).join(",") !== "library") fail("generic value alpha rename did not change token-stream implementation identity");
    if (checkedEnvOwnersChanged(genericValueT, genericValueU).length !== 0) fail("alpha-equivalent generic value rename changed checked environment identity");

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
    if (implementationOwnersChanged(traitBoundShow, traitBoundEq).join(",") !== "library") fail("trait method generic bound edit did not change token-stream implementation identity");

    // Schema 6 consumes both trait-header and method-generic source binders.
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[T] { project[U: Eq](T, U, Foreign) -> T }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitHeaderT = check("trait_header_t");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[A] { project[B: Eq](A, B, Foreign) -> A }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitHeaderA = check("trait_header_a");
    if (interfaceOwnersChanged(traitHeaderT, traitHeaderA).length !== 0) fail("alpha-equivalent trait header/method binder rename changed interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[A, C] { project[B: Eq](A, B, Foreign) -> A }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitHeaderArity = check("trait_header_arity");
    if (interfaceOwnersChanged(traitHeaderA, traitHeaderArity).join(",") !== "library") fail("trait header binder arity did not change interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[A, C] { project[B: Show](A, B, Foreign) -> A }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitScopedBound = check("trait_scoped_bound");
    if (interfaceOwnersChanged(traitHeaderArity, traitScopedBound).join(",") !== "library") fail("trait method binder bound did not change interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[A, C] { project[B: Show](A, B, Foreign) -> B }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitScopedSignature = check("trait_scoped_signature");
    if (interfaceOwnersChanged(traitScopedBound, traitScopedSignature).join(",") !== "library") fail("trait method signature did not change interface identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport struct Foreign {}\nexport struct Other {}\nexport trait Scoped[A, C] { project[B: Show](A, B, Other) -> B }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitFreeName = check("trait_free_name");
    if (interfaceOwnersChanged(traitScopedSignature, traitFreeName).join(",") !== "library") fail("free nominal type name did not remain distinct in trait interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait ParentA { parent_a(Int) -> Int }\nexport trait ParentB { parent_b(Int) -> Int }\nexport trait Child: ParentA { child(Int) -> Int }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitSuperA = check("trait_super_a");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait ParentA { parent_a(Int) -> Int }\nexport trait ParentB { parent_b(Int) -> Int }\nexport trait Child: ParentB { child(Int) -> Int }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const traitSuperB = check("trait_super_b");
    if (interfaceOwnersChanged(traitSuperA, traitSuperB).join(",") !== "library") fail("exported trait supertrait edit did not change interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Logger { Info(String) -> Unit }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const effectString = check("effect_operation_string");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Logger { Info(Int) -> Unit }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const effectInt = check("effect_operation_int");
    if (interfaceOwnersChanged(effectString, effectInt).join(",") !== "library") fail("exported effect operation signature edit did not change interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Ask { Get -> Int; Put(Int) -> Unit }\nexport effectset AskAll = { Ask::Get }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const effectsetGet = check("effectset_get");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport effect Ask { Get -> Int; Put(Int) -> Unit }\nexport effectset AskAll = { Ask::Get, Ask::Put }\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const effectsetGetPut = check("effectset_get_put");
    if (interfaceOwnersChanged(effectsetGet, effectsetGetPut).join(",") !== "library") fail("exported effectset member edit did not change interface identity");

    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U: Eq](U) -> U }\nimpl [T: Eq] Eq for Option[T]\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const implBoundEq = check("impl_bound_eq");
    if (implementationOwnersChanged(traitBoundEq, implBoundEq).join(",") !== "library") fail("impl generic bound addition did not change token-stream implementation identity");
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U: Eq](U) -> U }\nimpl [T: Show] Eq for Option[T]\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const implBoundShow = check("impl_bound_show");
    if (implementationOwnersChanged(implBoundEq, implBoundShow).join(",") !== "library") fail("impl generic bound edit did not change token-stream implementation identity");
    if (interfaceOwnersChanged(implBoundEq, implBoundShow).length !== 0) fail("impl-bound edit changed the exported interface identity even though impls have no export surface bit");
    if (checkedEnvOwnersChanged(implBoundEq, implBoundShow).length !== 0) fail("impl-bound edit changed the value-only checked environment identity");
    if (persistentTypeEnvTransportOwnersChanged(implBoundEq, implBoundShow).length !== 0) {
      fail("unselected Eq impl-bound edit changed the selected persistent TypeEnv transport identity")
    }
    writeFileSync(join(project, "library.vibe"), "import ./base.vibe { base_value }\nexport trait Identity { identity[U: Eq](U) -> U }\nimpl [T: Show] Eq for Array[T]\nexport let library_value = \"changed\"\nfn private_offset() -> Int { 2 }\n");
    const implTargetArray = check("impl_target_array");
    if (interfaceOwnersChanged(implBoundShow, implTargetArray).length !== 0) fail("impl-target edit changed the exported interface identity even though impls have no export surface bit");
    if (persistentTypeEnvTransportOwnersChanged(implBoundShow, implTargetArray).length !== 0) {
      fail("unselected Eq impl-target edit changed the selected persistent TypeEnv transport identity")
    }

    writeFileSync(join(project, "app.vibe"), "import ./base.vibe { base_value }\nimport ./library.vibe { library_value }\nfn main() -> Int { let _ = library_value\nbase_value(0) }\n");
    const planEdit = check("dependency_plan_edit");
    if (sourceOwnersChanged(implTargetArray, planEdit).join(",") !== "app") fail("dependency-plan edit source delta drift");
    if (implementationOwnersChanged(implTargetArray, planEdit).join(",") !== "app") fail("dependency-plan edit implementation delta drift");
    if (JSON.stringify(decisionsByName(planEdit)) !== JSON.stringify({ base: "reused", library: "reused", app: "rechecked" })) {
      fail("dependency-plan edit current decision drift");
    }
    const appDependencies = moduleByName(planEdit, "app").direct_dependencies.map((path) => basename(path));
    if (appDependencies.join(",") !== "base.vibe,library.vibe") fail("dependency-plan trace did not record the added base import in declaration order");
    runPlannerCase("dependency_plan_edit", implTargetArray, planEdit);

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

    // #1548: persist the shadow planner vs current compiler decision diff.
    // Published only after every case above succeeded, atomically via rename,
    // and strictly re-parsed first so a torn or malformed artifact cannot ship.
    let shadowDecisionDiff;
    if (diffOut) {
      const artifact = buildShadowDecisionDiffArtifact(shadowDiffCases, {
        scenario: "three-module-incremental-invalidation",
        stage2_sha256: createHash("sha256").update(readFileSync(stage2)).digest("hex"),
      });
      const rendered = `${JSON.stringify(artifact, null, 2)}\n`;
      parseShadowDecisionDiffArtifact(rendered);
      mkdirSync(dirname(diffOut), { recursive: true });
      const partial = `${diffOut}.partial-${process.pid}`;
      writeFileSync(partial, rendered);
      renameSync(partial, diffOut);
      shadowDecisionDiff = { written_to: diffOut, totals: artifact.totals };
    }

    console.log(JSON.stringify({
      schema: 6,
      scenario: "three-module-incremental-invalidation",
      model_private_body_typing_invalidated: ["library"],
      current_private_body_rechecked: currentPrivateRechecks,
      conservative_over_invalidation: currentPrivateRechecks.filter((name) => name !== "library"),
      private_dependency_classification: privateDependencyClassification,
      planner_cases: plannerCases,
      ...(shadowDecisionDiff ? { shadow_decision_diff: shadowDecisionDiff } : {}),
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
