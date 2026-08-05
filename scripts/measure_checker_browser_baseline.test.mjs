import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { parseCheckerBrowserBaselineReport, parseModulePlan } from "./measure_checker_browser_baseline.mjs";

const plan = "version\t1\nmodule\t0\t0\tdep.vibe\nmodule\t1\t1\tmain.vibe\ndep\t1\tdep.vibe\n";

const sourceHash = "a".repeat(64);
const artifactHash = "b".repeat(64);
const closureHash = createHash("sha256").update(`0\t0\troot.vibe\t1\t${sourceHash}\t`).digest("hex");

function available(id) {
  const roots = {
    parser_only: { path: "bench/checker_browser_baseline/parser_only.vibe", entry: "main" },
    current_checker: { path: "bench/checker_browser_baseline/current_checker.vibe", entry: "main" },
    full_compiler: { path: "lib/@vibe/compiler/cli_adapter.vibe", entry: "cli_main" },
  };
  return {
    id,
    status: "available",
    root: roots[id],
    module_plan: {
      authority: "VIBE_MODULE_PLAN=1 version 1 sidecar; ingested .src files",
      dependency_order: "canonical compiler plan order (index ascending)",
      module_count: 1,
      total_bytes: 1,
      sha256: closureHash,
      modules: [{ index: 0, rank: 0, path: "root.vibe", dependencies: [], bytes: 1, sha256: sourceHash, category: "benchmark_root", manifest_annotation: "not-listed" }],
      category_breakdown: { benchmark_root: { modules: 1, bytes: 1 } },
    },
    artifacts: { raw_bytes: 1, gzip_bytes: 1, brotli_bytes: 1, sha256: artifactHash, imports: [], repeated_sha256: [artifactHash, artifactHash], repeated_artifacts_equal: true },
    timings: { build_ms: [1, 2], wasm_compile_ms: [1, 2], wasm_instantiate_ms: [1, 2], direct_entry_ms: [1, 2], unsupported: {} },
  };
}

function report() {
  return {
    schema: 1,
    methodology: { opt_in: true, cache_policy: "isolated", source_authority: "VIBE_MODULE_PLAN=1", unavailable_policy: "explicit", timing_policy: "raw samples", samples: 2 },
    environment: { node: "v", v8: "v", platform: "p", release: "r", arch: "a", cpu_model: "c", cpu_count: 1, cwd: "root", isolated_workdir_parent: "_build" },
    compiler: { path: "stage2.wasm", sha256: "c".repeat(64), matching_contract: "caller supplied" },
    cases: [
      available("parser_only"),
      available("current_checker"),
      available("full_compiler"),
      { id: "checker_engine_only", status: "unavailable", unavailable_reason: "no entry" },
      { id: "checker_engine_plus_artifacts", status: "unavailable", unavailable_reason: "no entry" },
      { id: "full_compiler_check", status: "unavailable", unavailable_reason: "no ABI" },
    ],
  };
}

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

test("report parser accepts exact baseline schema with explicit unavailable cases", () => {
  const value = report();
  assert.deepEqual(parseCheckerBrowserBaselineReport(JSON.stringify(value)), value);
});

test("report parser rejects widened reports and unavailable zero metrics", () => {
  const widened = report();
  widened.extra = true;
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(widened)), /unexpected or missing fields/);
  const dishonest = report();
  dishonest.cases[3].timings = { build_ms: [0] };
  assert.throws(() => parseCheckerBrowserBaselineReport(JSON.stringify(dishonest)), /unexpected or missing fields/);
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
});
