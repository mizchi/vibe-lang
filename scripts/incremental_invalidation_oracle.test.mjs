import assert from "node:assert/strict";
import test from "node:test";

import {
  compareObservedInvalidation,
  parseIncrementalInvalidationTrace,
  planObservedTypingInvalidation,
} from "./incremental_invalidation_oracle.mjs";

const validTrace = {
  schema: 2,
  run_nonce: "unit-nonce",
  fingerprint_note: "source_fingerprint is an ingested-source identity; interface_fingerprint is an observation only, never a production cache key", 
  modules: [
    {
      path: "base.vibe",
      direct_dependencies: [],
      source_fingerprint: "20:1:2",
      source_fingerprint_kind: "compact_string_fingerprint(ingested_source)",
      interface_fingerprint: "31:1:2",
      interface_fingerprint_kind: "compact_string_fingerprint(vibe-module-interface:v1 canonical exported surface)",
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

test("incremental invalidation trace accepts its versioned successful schema", () => {
  assert.deepEqual(parseIncrementalInvalidationTrace(JSON.stringify(validTrace), "unit-nonce"), validTrace);
});

test("incremental invalidation trace rejects stale, dishonest, and incomplete sidecars", () => {
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(validTrace), "other"), /run_nonce mismatch/);
  const dishonest = structuredClone(validTrace);
  dishonest.modules[0].source_fingerprint_kind = "interface_fingerprint";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(dishonest)), /dishonest fingerprint kind/);
  const incomplete = structuredClone(validTrace);
  delete incomplete.modules[0].interface_fingerprint;
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(incomplete)), /missing interface fingerprint/);
  const stale = structuredClone(validTrace);
  stale.modules[0].decision = "rechecked";
  assert.throws(() => parseIncrementalInvalidationTrace(JSON.stringify(stale)), /rechecked decision count mismatch/);
});

function plannerTrace({ source = {}, iface = {}, deps = {}, rechecked = [] } = {}) {
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
      interface_fingerprint: iface[path] ?? `interface:${path}`,
      decision: rechecked.includes(path) ? "rechecked" : "reused",
    })),
  };
}

test("shadow planner keeps source-only edits local and propagates interface edits transitively", () => {
  const before = plannerTrace();
  const privateAfter = plannerTrace({
    source: { "/p/library.vibe": "source:library:private-edit" },
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
    iface: { "/p/library.vibe": "interface:library:changed" },
    rechecked: ["/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, publicAfter), ["/p/library.vibe", "/p/app.vibe"]);

  // The base interface change must cross the before-only base -> library edge,
  // then reach app. A dependency-plan owner invalidation alone must not
  // propagate, so app protects the union-graph reverse-closure requirement.
  const removedEdgeAfter = plannerTrace({
    source: { "/p/base.vibe": "source:base:public-edit", "/p/library.vibe": "source:library:removed-import" },
    iface: { "/p/base.vibe": "interface:base:changed" },
    deps: { "/p/library.vibe": [] },
    rechecked: ["/p/base.vibe", "/p/library.vibe", "/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, removedEdgeAfter), ["/p/base.vibe", "/p/library.vibe", "/p/app.vibe"]);
});

test("shadow planner covers dependency-plan edits and rejects under-invalidation", () => {
  const before = plannerTrace();
  const planAfter = plannerTrace({
    source: { "/p/app.vibe": "source:app:added-import" },
    deps: { "/p/app.vibe": ["/p/base.vibe", "/p/library.vibe"] },
    rechecked: ["/p/app.vibe"],
  });
  assert.deepEqual(planObservedTypingInvalidation(before, planAfter), ["/p/app.vibe"]);

  const underInvalidated = plannerTrace({
    source: { "/p/library.vibe": "source:library:public-edit" },
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
