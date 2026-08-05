import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  isolatedCompilerEnvironment,
  parseCheckerBrowserBaselineReport,
  parseModulePlan,
  validateCaseClosure,
} from "./measure_checker_browser_baseline.mjs";

const plan = "version\t1\nmodule\t0\t0\tdep.vibe\nmodule\t1\t1\tmain.vibe\ndep\t1\tdep.vibe\n";
const sourceHash = "a".repeat(64);
const artifactHash = "b".repeat(64);
const artifactPrefix = "lib/@vibe/compiler/checker/artifacts/";

function closureDigest(modules) {
  return createHash("sha256").update(modules.map((module) => `${module.index}\t${module.rank}\t${module.path}\t${module.bytes}\t${module.sha256}\t${module.dependencies.join("\u0000")}`).join("\n")).digest("hex");
}

function sourceModule(index, path, category) {
  return { index, rank: 0, path, dependencies: [], bytes: 1, sha256: sourceHash, category, manifest_annotation: "not-listed" };
}

function available(id) {
  const roots = {
    parser_only: { path: "bench/checker_browser_baseline/parser_only.vibe", entry: "main" },
    current_checker: { path: "bench/checker_browser_baseline/current_checker.vibe", entry: "main" },
    checker_engine_only: { path: "bench/checker_browser_baseline/checker_engine_only.vibe", entry: "main" },
    checker_engine_plus_artifacts: { path: "bench/checker_browser_baseline/checker_engine_plus_artifacts.vibe", entry: "main" },
    full_compiler: { path: "lib/@vibe/compiler/cli_adapter.vibe", entry: "cli_main" },
  };
  let modules;
  if (id === "checker_engine_plus_artifacts") {
    modules = [
      sourceModule(0, roots[id].path, "benchmark_root"),
      sourceModule(1, `${artifactPrefix}checked_effect_set_artifact.vibe`, "checker_artifacts_artifact"),
      sourceModule(2, `${artifactPrefix}checked_effect_set_observation.vibe`, "checker_artifacts_observation"),
      sourceModule(3, `${artifactPrefix}index.vpkg`, "checker_artifacts_contract"),
    ];
  } else {
    const path = roots[id].path;
    modules = [sourceModule(0, path, path.startsWith("bench/") ? "benchmark_root" : "compiler_other")];
  }
  const category_breakdown = {};
  for (const module of modules) {
    if (!category_breakdown[module.category]) category_breakdown[module.category] = { modules: 0, bytes: 0 };
    category_breakdown[module.category].modules += 1;
    category_breakdown[module.category].bytes += module.bytes;
  }
  return {
    id,
    status: "available",
    root: roots[id],
    module_plan: {
      authority: "VIBE_MODULE_PLAN=1 version 1 sidecar; ingested .src files",
      dependency_order: "canonical compiler plan order (index ascending)",
      module_count: modules.length,
      total_bytes: modules.length,
      sha256: closureDigest(modules),
      modules,
      category_breakdown,
    },
    artifacts: { raw_bytes: 1, gzip_bytes: 1, brotli_bytes: 1, sha256: artifactHash, imports: [], repeated_sha256: [artifactHash, artifactHash], repeated_artifacts_equal: true },
    timings: { build_ms: [1, 2], wasm_compile_ms: [1, 2], wasm_instantiate_ms: [1, 2], direct_entry_ms: [1, 2], unsupported: {} },
  };
}

function report() {
  return {
    schema: 2,
    methodology: { opt_in: true, cache_policy: "isolated", source_authority: "VIBE_MODULE_PLAN=1", unavailable_policy: "explicit", timing_policy: "raw samples", samples: 2 },
    environment: { node: "v", v8: "v", platform: "p", release: "r", arch: "a", cpu_model: "c", cpu_count: 1, cwd: "root", isolated_workdir_parent: "_build" },
    compiler: { path: "stage2.wasm", sha256: "c".repeat(64), matching_contract: "caller supplied" },
    cases: [
      available("parser_only"),
      available("current_checker"),
      available("checker_engine_only"),
      available("checker_engine_plus_artifacts"),
      available("full_compiler"),
      { id: "full_compiler_check", status: "unavailable", unavailable_reason: "no ABI" },
    ],
  };
}

function replaceClosure(item, modules) {
  item.module_plan.modules = modules;
  item.module_plan.module_count = modules.length;
  item.module_plan.total_bytes = modules.reduce((total, module) => total + module.bytes, 0);
  item.module_plan.sha256 = closureDigest(modules);
  item.module_plan.category_breakdown = {};
  for (const module of modules) {
    const breakdown = item.module_plan.category_breakdown;
    if (!breakdown[module.category]) breakdown[module.category] = { modules: 0, bytes: 0 };
    breakdown[module.category].modules += 1;
    breakdown[module.category].bytes += module.bytes;
  }
}

test("compiler subprocess environment rejects inherited adapter modes", () => {
  assert.deepEqual(
    isolatedCompilerEnvironment(
      { VIBE_FS_COMPILE: "1", VIBE_RC: "0" },
      { PATH: "/bin", VIBE_MODULE_PLAN: "1", VIBE_CHECK_ONLY: "1", VIBE_CFG: "inherited" },
    ),
    { PATH: "/bin", VIBE_FS_COMPILE: "1", VIBE_RC: "0" },
  );
});

test("module plan accepts canonical ingested-source sidecar ordering", () => {
  assert.deepEqual(parseModulePlan(plan), [
    { index: 0, rank: 0, path: "dep.vibe", dependencies: [] },
    { index: 1, rank: 1, path: "main.vibe", dependencies: ["dep.vibe"] },
  ]);
});

test("module plan rejects malformed, non-contiguous, and guessed dependencies", () => {
  assert.throws(() => parseModulePlan("version\t2\n"), /unsupported module plan version/);
  assert.throws(() => parseModulePlan("version\t1\nmodule\t1\t0\tmain.vibe\n"), /noncanonical module plan row/);
  assert.throws(() => parseModulePlan("version\t1\nmodule\t0\t0\tdep.vibe\nmodule\t1\t1\tmain.vibe\ndep\t0\tdep.vibe\n"), /noncanonical dependency plan row/);
  assert.throws(() => parseModulePlan("version\t1\nmodule\t0\t0\tz.vibe\nmodule\t1\t0\ta.vibe\n"), /not sorted by canonical rank\/path order/);
  assert.throws(() => parseModulePlan("version\t1\nmodule\t0\t0\tdep.vibe\nmodule\t1\t99\tmain.vibe\ndep\t1\tdep.vibe\n"), /noncanonical rank/);
  assert.throws(() => parseModulePlan("version\t1\nmodule\t0\t0\tmain.vibe\ndep\t0\tmissing.vibe\n"), /absent from closure/);
});

test("schema 2 accepts five fixed measured cases and only honest full-check unavailability", () => {
  const value = report();
  assert.deepEqual(parseCheckerBrowserBaselineReport(JSON.stringify(value)), value);
});

test("live engine closure policies reject forbidden ownership and require invoked artifact evidence", () => {
  assert.doesNotThrow(() => validateCaseClosure("checker_engine_only", [{ path: "lib/@vibe/compiler/checker/checker.vibe" }]));
  assert.throws(() => validateCaseClosure("checker_engine_only", [{ path: `${artifactPrefix}index.vpkg` }]), /checker artifacts child/);
  for (const ownership of ["codegen", "perceus", "runtime", "cache", "loader"]) {
    assert.throws(() => validateCaseClosure("checker_engine_only", [{ path: `lib/@vibe/compiler/${ownership}/bad.vibe` }]), new RegExp(`forbidden ${ownership}`));
    assert.throws(() => validateCaseClosure("checker_engine_plus_artifacts", [{ path: `lib/@vibe/compiler/${ownership}/bad.vibe` }]), new RegExp(`forbidden ${ownership}`));
  }
  const exactEvidence = [
    { path: `${artifactPrefix}index.vpkg` },
    { path: `${artifactPrefix}checked_effect_set_artifact.vibe` },
    { path: `${artifactPrefix}checked_effect_set_observation.vibe` },
  ];
  assert.doesNotThrow(() => validateCaseClosure("checker_engine_plus_artifacts", exactEvidence));
  assert.throws(() => validateCaseClosure("checker_engine_plus_artifacts", exactEvidence.slice(1)), /missing child contract/);
  assert.throws(() => validateCaseClosure("checker_engine_plus_artifacts", exactEvidence.slice(0, 2)), /missing invoked artifact source/);
});

test("report parser rejects widened reports, reordered availability, and unavailable zero metrics", () => {
  const widened = report();
  widened.extra = true;
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(widened)), /unexpected or missing fields/);
  const dishonest = report();
  dishonest.cases[5].timings = { build_ms: [0] };
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(dishonest)), /unexpected or missing fields/);
  const reordered = report();
  [reordered.cases[1], reordered.cases[2]] = [reordered.cases[2], reordered.cases[1]];
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(reordered)), /case order or IDs changed/);
  const unavailableEngine = report();
  unavailableEngine.cases[2] = { id: "checker_engine_only", status: "unavailable", unavailable_reason: "pretend" };
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(unavailableEngine)), /required measured case is unavailable/);
});

test("serialized report requires every declared root exactly once in its module plan", () => {
  const missingRoot = report();
  replaceClosure(missingRoot.cases[3], [
    sourceModule(0, `${artifactPrefix}checked_effect_set_artifact.vibe`, "checker_artifacts_artifact"),
    sourceModule(1, `${artifactPrefix}checked_effect_set_observation.vibe`, "checker_artifacts_observation"),
    sourceModule(2, `${artifactPrefix}index.vpkg`, "checker_artifacts_contract"),
  ]);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(missingRoot)), /must contain declared root exactly once/);
});

test("report parser rejects false authority, root, closure, digest, import, and category evidence", () => {
  const wrongAuthority = report();
  wrongAuthority.cases[0].module_plan.authority = "imports guessed from text";
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(wrongAuthority)), /dishonest module-plan authority/);
  const wrongRoot = report();
  wrongRoot.cases[0].root.path = "unrelated.vibe";
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(wrongRoot)), /unexpected fixed root/);
  const wrongRank = report();
  wrongRank.cases[0].module_plan.modules[0].rank = 99;
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(wrongRank)), /noncanonical rank/);
  const wrongTotals = report();
  wrongTotals.cases[0].module_plan.total_bytes = 2;
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(wrongTotals)), /source byte total mismatch/);
  const wrongRepeat = report();
  wrongRepeat.cases[0].artifacts.repeated_sha256[1] = "d".repeat(64);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(wrongRepeat)), /repeated artifact digest mismatch/);
  const unsortedImports = report();
  unsortedImports.cases[0].artifacts.imports = [
    { module: "z", name: "a", kind: "function" },
    { module: "a", name: "z", kind: "function" },
  ];
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(unsortedImports)), /noncanonical Wasm import order/);
  const mislabeledCategory = report();
  mislabeledCategory.cases[3].module_plan.modules[0].category = "checker_artifact";
  mislabeledCategory.cases[3].module_plan.category_breakdown = { checker_artifact: { modules: 1, bytes: 1 } };
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(mislabeledCategory)), /module category mismatch/);
});

test("serialized closure policies reject engine contamination and missing exact artifact sources", () => {
  const contaminatedCurrent = report();
  replaceClosure(contaminatedCurrent.cases[1], [
    sourceModule(0, contaminatedCurrent.cases[1].root.path, "benchmark_root"),
    sourceModule(1, "lib/@vibe/compiler/codegen/contamination.vibe", "codegen"),
  ]);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(contaminatedCurrent)), /current_checker closure includes codegen source/);

  const contaminatedEngine = report();
  replaceClosure(contaminatedEngine.cases[2], [
    sourceModule(0, contaminatedEngine.cases[2].root.path, "benchmark_root"),
    sourceModule(1, "lib/@vibe/compiler/runtime/contamination.vibe", "runtime"),
  ]);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(contaminatedEngine)), /checker_engine_only closure includes forbidden runtime source/);

  const childInEngine = report();
  replaceClosure(childInEngine.cases[2], [
    sourceModule(0, childInEngine.cases[2].root.path, "benchmark_root"),
    sourceModule(1, `${artifactPrefix}index.vpkg`, "checker_artifacts_contract"),
  ]);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(childInEngine)), /checker artifacts child/);

  const missingArtifact = report();
  replaceClosure(missingArtifact.cases[3], [
    sourceModule(0, missingArtifact.cases[3].root.path, "benchmark_root"),
    sourceModule(1, `${artifactPrefix}checked_effect_set_observation.vibe`, "checker_artifacts_observation"),
    sourceModule(2, `${artifactPrefix}index.vpkg`, "checker_artifacts_contract"),
  ]);
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(missingArtifact)), /missing invoked artifact source/);

  const fullCompilerCodegen = report();
  replaceClosure(fullCompilerCodegen.cases[4], [
    sourceModule(0, fullCompilerCodegen.cases[4].root.path, "compiler_other"),
    sourceModule(1, "lib/@vibe/compiler/codegen/allowed.vibe", "codegen"),
  ]);
  assert.deepEqual(parseCheckerBrowserBaselineReport(JSON.stringify(fullCompilerCodegen)), fullCompilerCodegen);
});
