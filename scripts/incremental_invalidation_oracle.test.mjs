import assert from "node:assert/strict";
import test from "node:test";

import {
  compareObservedInvalidation,
  compareSuccessfulIncrementalInvalidationTraces,
  parseIncrementalInvalidationTrace,
  planObservedTypingInvalidation,
} from "./incremental_invalidation_oracle.mjs";

const validTrace = {
  schema: 6,
  run_nonce: "unit-nonce",
  fingerprint_note: "source_fingerprint is ingestion telemetry; implementation_fingerprint remains the provisional canonical token-stream identity; interface_fingerprint, checked_env_fingerprint, and persistent_type_env_transport_fingerprint are observation only; persistent_type_env_transport_fingerprint is TypeEnv transport only, not CheckedProgram, typed IR, exported interface, cache key, or reuse decision; none is a production cache key",
  modules: [
    {
      path: "base.vibe",
      direct_dependencies: [],
      source_fingerprint: "20:1:2",
      source_fingerprint_kind: "compact_string_fingerprint(ingested_source)",
      implementation_fingerprint: "30:1:2",
      implementation_fingerprint_kind: "compact_string_fingerprint(vibe-module-token-stream:v1 length_delimited(token_kind,source_lexeme))",
      interface_fingerprint: "31:1:2",
      interface_fingerprint_kind: "compact_string_fingerprint(vibe-module-interface:v2 canonical exported surface including trait-header and method-generic binders)",
      checked_env_fingerprint: "32:1:2",
      checked_env_fingerprint_kind: "compact_string_fingerprint(vibe-module-checked-env:v1 canonical effective TypeEnv value bindings)",
      persistent_type_env_transport_fingerprint: "33:1:2",
      persistent_type_env_transport_fingerprint_kind: "compact_string_fingerprint(persistent_type_env_cache_text:v2 complete TypeEnv transport only; not CheckedProgram, typed IR, exported interface, cache key, or reuse decision)",
      decision: "reused",
    },
  ],
  aggregate_telemetry: {
    schema: 1,
    modules_planned: 1,
    modules_rechecked: 0,
    modules_reused: 1,
    parse_operations: 0,
    modules_failed_or_blocked: 0,
  },
};

test("incremental invalidation trace accepts schema 6 successful observations", () => {
  assert.deepEqual(parseIncrementalInvalidationTrace(JSON.stringify(validTrace), "unit-nonce"), validTrace);
});

test("incremental invalidation trace rejects stale, missing, and dishonest identities", () => {
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(validTrace), "other"), /run_nonce mismatch/);
  const dishonestSource = structuredClone(validTrace);
  dishonestSource.modules[0].source_fingerprint_kind = "interface_fingerprint";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonestSource)), /dishonest source fingerprint kind/);
  const dishonestImplementation = structuredClone(validTrace);
  dishonestImplementation.modules[0].implementation_fingerprint_kind = "typed-ir";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonestImplementation)), /dishonest implementation fingerprint kind/);
  const incomplete = structuredClone(validTrace);
  delete incomplete.modules[0].implementation_fingerprint;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(incomplete)), /missing module row implementation_fingerprint/);
  const schema5 = structuredClone(validTrace);
  schema5.schema = 5;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(schema5)), /unsupported schema 5/);
  const schema3 = structuredClone(validTrace);
  schema3.schema = 3;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(schema3)), /unsupported schema 3/);
  const dishonestCheckedEnv = structuredClone(validTrace);
  dishonestCheckedEnv.modules[0].checked_env_fingerprint_kind = "persistent-env-codec";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonestCheckedEnv)), /dishonest checked environment fingerprint kind/);
  const missingCheckedEnv = structuredClone(validTrace);
  delete missingCheckedEnv.modules[0].checked_env_fingerprint;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(missingCheckedEnv)), /missing module row checked_env_fingerprint/);
  const dishonestTransport = structuredClone(validTrace);
  dishonestTransport.modules[0].persistent_type_env_transport_fingerprint_kind = "typed-ir";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonestTransport)), /dishonest persistent TypeEnv transport fingerprint kind/);
  const missingTransport = structuredClone(validTrace);
  delete missingTransport.modules[0].persistent_type_env_transport_fingerprint;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(missingTransport)), /missing module row persistent_type_env_transport_fingerprint/);
  const dishonestNote = structuredClone(validTrace);
  dishonestNote.fingerprint_note = "observation only";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonestNote)), /dishonest fingerprint_note/);
  const unexpectedField = structuredClone(validTrace);
  unexpectedField.modules[0].extra = "unexpected";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(unexpectedField)), /unexpected module row keys/);
  const stale = structuredClone(validTrace);
  stale.modules[0].decision = "rechecked";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(stale)), /rechecked decision count mismatch/);
});

function parsedComparisonTrace(nonce) {
  const trace = structuredClone(validTrace);
  const row = (path, dependencies, suffix) => ({
    ...structuredClone(validTrace.modules[0]),
    path,
    direct_dependencies: dependencies,
    source_fingerprint: `source:${suffix}`,
    implementation_fingerprint: `implementation:${suffix}`,
    interface_fingerprint: `interface:${suffix}`,
    checked_env_fingerprint: `checked-env:${suffix}`,
    persistent_type_env_transport_fingerprint: `persistent-type-env-transport:${suffix}`,
  });
  trace.run_nonce = nonce;
  trace.modules = [
    row("base.vibe", [], "base"),
    row("library.vibe", ["base.vibe"], "library"),
    row("app.vibe", ["base.vibe", "library.vibe"], "app"),
  ];
  trace.aggregate_telemetry = {
    schema: 1,
    modules_planned: 3,
    modules_rechecked: 0,
    modules_reused: 3,
    parse_operations: 0,
    modules_failed_or_blocked: 0,
  };
  return parseIncrementalInvalidationTrace(JSON.stringify(trace), nonce);
}

test("successful trace semantic comparison excludes only run_nonce", () => {
  const expected = parsedComparisonTrace("comparison-expected");
  const actual = parsedComparisonTrace("comparison-actual");
  assert.doesNotThrow(() => compareSuccessfulIncrementalInvalidationTraces(expected, actual));

  const fingerprintMismatch = structuredClone(actual);
  fingerprintMismatch.modules[1].implementation_fingerprint = "implementation:changed";
  assert.throws(
    () => compareSuccessfulIncrementalInvalidationTraces(expected, fingerprintMismatch),
    /modules\[1\]\(library\.vibe\)\.implementation_fingerprint/,
  );

  const transportMismatch = structuredClone(actual);
  transportMismatch.modules[1].persistent_type_env_transport_fingerprint = "persistent-type-env-transport:changed";
  assert.throws(
    () => compareSuccessfulIncrementalInvalidationTraces(expected, transportMismatch),
    /modules\[1\]\(library\.vibe\)\.persistent_type_env_transport_fingerprint/,
  );

  const dependencyOrderMismatch = structuredClone(actual);
  dependencyOrderMismatch.modules[2].direct_dependencies.reverse();
  assert.throws(
    () => compareSuccessfulIncrementalInvalidationTraces(expected, dependencyOrderMismatch),
    /modules\[2\]\(app\.vibe\)\.direct_dependencies\[0\]/,
  );

  // Keep this altered trace internally valid: the decision counts still
  // partition planned modules, so rejection comes from semantic comparison.
  const decisionMismatch = structuredClone(actual);
  decisionMismatch.modules[0].decision = "rechecked";
  decisionMismatch.aggregate_telemetry.modules_rechecked = 1;
  decisionMismatch.aggregate_telemetry.modules_reused = 2;
  const parsedDecisionMismatch = parseIncrementalInvalidationTrace(JSON.stringify(decisionMismatch), "comparison-actual");
  assert.throws(
    () => compareSuccessfulIncrementalInvalidationTraces(expected, parsedDecisionMismatch),
    /modules\[0\]\(base\.vibe\)\.decision/,
  );

  // parse_operations is independent aggregate accounting, making this a
  // valid successful trace with deliberately different observed telemetry.
  const telemetryMismatch = structuredClone(actual);
  telemetryMismatch.aggregate_telemetry.parse_operations = 1;
  const parsedTelemetryMismatch = parseIncrementalInvalidationTrace(JSON.stringify(telemetryMismatch), "comparison-actual");
  assert.throws(
    () => compareSuccessfulIncrementalInvalidationTraces(expected, parsedTelemetryMismatch),
    /aggregate_telemetry\.parse_operations/,
  );
});

test("incremental invalidation trace rejects dependencies outside its complete module universe", () => {
  const outsideUniverse = structuredClone(validTrace);
  outsideUniverse.modules[0].direct_dependencies = ["missing.vibe"];
  assert.throws(
    () => parseIncrementalInvalidationTrace(JSON.stringify(outsideUniverse)),
    /direct dependency outside trace module universe/,
  );
});

function plannerTrace({ source = {}, implementation = {}, iface = {}, deps = {}, rechecked = [] } = {}) {
  const paths = ["/p/base.vibe", "/p/library.vibe", "/p/app.vibe"];
  const defaultDeps = {
    "/p/base.vibe": [],
    "/p/library.vibe": ["/p/base.vibe"],
    "/p/app.vibe": ["/p/library.vibe"],
  };
  return {
    modules: paths.map((path) => ({
      path,
      direct_dependencies: deps[path] ?? defaultDeps[path],
      source_fingerprint: source[path] ?? `source:${path}`,
      implementation_fingerprint: implementation[path] ?? `implementation:${path}`,
      interface_fingerprint: iface[path] ?? `interface:${path}`,
      decision: rechecked.includes(path) ? "rechecked" : "reused",
    })),
  };
}

test("shadow planner treats source-only changes as ingestion telemetry", () => {
  const before = plannerTrace();
  const commentAfter = plannerTrace({
    source: { "/p/library.vibe": "source:library:comment-edit" },
    rechecked: ["/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, commentAfter), []);
  assert.deepEqual(compareObservedInvalidation(before, commentAfter), {
    planned: [],
    observed: ["/p/library.vibe", "/p/app.vibe"],
    conservative_over_invalidation: ["/p/library.vibe", "/p/app.vibe"],
  });
});

test("shadow planner keeps implementation edits local and propagates interface edits transitively", () => {
  const before = plannerTrace();
  const privateAfter = plannerTrace({
    source: { "/p/library.vibe": "source:library:private-edit" },
    implementation: { "/p/library.vibe": "implementation:library:private-edit" },
    rechecked: ["/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, privateAfter), ["/p/library.vibe"]);
  assert.deepEqual(compareObservedInvalidation(before, privateAfter), {
    planned: ["/p/library.vibe"],
    observed: ["/p/library.vibe", "/p/app.vibe"],
    conservative_over_invalidation: ["/p/app.vibe"],
  });

  const publicAfter = plannerTrace({
    source: { "/p/library.vibe": "source:library:public-edit" },
    implementation: { "/p/library.vibe": "implementation:library:public-edit" },
    iface: { "/p/library.vibe": "interface:library:changed" },
    rechecked: ["/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, publicAfter), ["/p/library.vibe", "/p/app.vibe"]);

  // The base interface change crosses the before-only base -> library edge,
  // then reaches app. This guards union-graph reverse closure.
  const removedEdgeAfter = plannerTrace({
    source: { "/p/base.vibe": "source:base:public-edit", "/p/library.vibe": "source:library:removed-import" },
    implementation: { "/p/base.vibe": "implementation:base:public-edit", "/p/library.vibe": "implementation:library:removed-import" },
    iface: { "/p/base.vibe": "interface:base:changed" },
    deps: { "/p/library.vibe": [] },
    rechecked: ["/p/base.vibe", "/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, removedEdgeAfter), ["/p/base.vibe", "/p/library.vibe", "/p/app.vibe"]);
});

test("shadow planner retains dependency-plan owner semantics and rejects under-invalidation", () => {
  const before = plannerTrace();
  const planAfter = plannerTrace({
    source: { "/p/app.vibe": "source:app:added-import" },
    implementation: { "/p/app.vibe": "implementation:app:added-import" },
    deps: { "/p/app.vibe": ["/p/base.vibe", "/p/library.vibe"] },
    rechecked: ["/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, planAfter), ["/p/app.vibe"]);

  const underInvalidated = plannerTrace({
    implementation: { "/p/library.vibe": "implementation:library:public-edit" },
    iface: { "/p/library.vibe": "interface:library:changed" },
    rechecked: ["/p/library.vibe"],
  });
  assert.throws(() => compareObservedInvalidation(before, underInvalidated), /required recheck missing.*app\.vibe/);

  const unknownDependency = plannerTrace({ deps: { "/p/app.vibe": ["/p/missing.vibe"] } });
  assert.throws(() => planObservedTypingInvalidation(before, unknownDependency), /dependency outside module universe/);
  const changedUniverse = plannerTrace();
  changedUniverse.modules.pop();
  assert.throws(() => planObservedTypingInvalidation(before, changedUniverse), /unchanged module-path universe/);
});
