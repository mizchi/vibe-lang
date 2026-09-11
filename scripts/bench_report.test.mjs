import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const reportScript = new URL("./bench_report.mjs", import.meta.url);
const hashes = {
  seed_sha256: "seed",
  runner_sha256: "runner",
  bench_sha256: "bench",
};

// The report renders ONE representative row per size tier (Large/Medium/Small)
// plus
// coverage. These are the names it renders; a fixture that wants a row to
// appear has to use them.
const REP = {
  largeBench: "parser_bench.vibe::parse_checker_vibe",
  medium: "expr_eval",
  smallSample: "fib",
  smallBench: "pure_bench.vibe::fib30",
};

function run(args) {
  const result = spawnSync(process.execPath, [reportScript.pathname, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}

function withDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-"));
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}

// A snapshot whose representatives are all present and all flat.
const flatSnapshot = (commit) => ({
  commit,
  date: "2026-08-11",
  selfcompile: { heap_ptr_bytes: 1000, wall_ms_median: 100 },
  sizes: { stage2_wasm: 2048, cli_adapter_bundle: 4096, samples: { [REP.smallSample]: 648 } },
  benches: {
    [REP.largeBench]: { ns_p50: 5000, bytes_per_op: 7000 },
    [REP.smallBench]: { ns_p50: 5000, bytes_per_op: 0 },
    // A non-representative series, so the drift scan has something to scan.
    "alloc_bench.vibe::build_100": { ns_p50: 5000, bytes_per_op: 100 },
  },
  calibration: { label: "build_100", ns_p50: 10000, ...hashes },
});

function render(cur, base, cov) {
  return withDir((dir) => {
    const curP = join(dir, "current.json");
    writeFileSync(curP, JSON.stringify(cur));
    const args = [curP];
    if (base !== undefined) {
      const baseP = join(dir, "baseline.json");
      writeFileSync(baseP, JSON.stringify(base));
      args.push(baseP);
    }
    if (cov !== undefined) {
      if (args.length === 1) args.push(join(dir, "missing.json"));
      const covP = join(dir, "cov.json");
      writeFileSync(covP, JSON.stringify(cov));
      args.push(covP);
    }
    return run(args);
  });
}

test("advisory wall-time and calibration data are never rendered", () => {
  // Wildly different wall readings and an implausible calibration factor must
  // leave zero trace -- no wall rows, no ns/op rows, no calibration notes.
  for (const [factor, wall] of [[0.586, 80], [1.132, 500]]) {
    const base = flatSnapshot("baseline");
    const cur = flatSnapshot("current");
    cur.selfcompile.wall_ms_median = wall;
    cur.calibration.ns_p50 = Math.round(factor * 10000);
    cur.benches[REP.smallBench].ns_p50 = 9000;
    const report = render(cur, base);
    const body = report.split("\n").filter((l) => !l.startsWith("<sub>")).join("\n");
    assert.doesNotMatch(body, /wall_ms|ns\/op|Advisory|calibration|runner factor|runner mismatch|<details>/);
    assert.match(report, /wall times & runner calibration: recorded in the `bench-data` snapshots, not rendered/);
  }
});

test("the three tiers render one representative row each, with a per-cell delta", () => {
  const report = render(flatSnapshot("current"), flatSnapshot("baseline"));
  assert.match(report, /#### Large — the compiler itself/);
  assert.match(report, /#### Medium — a real program/);
  assert.match(report, /#### Small — micro/);
  // Large: memory / code / bench, each carrying its OWN delta. A single trailing
  // Δ column could not say which of the three moved.
  assert.match(report, /\| selfcompile \| 1000 B \(±0\) \| 2\.00 KiB \(±0\) \| 6\.84 KiB \(±0\) \|/);
  assert.match(report, /\| fib \| 648 B \(±0\) \| 0 B \(±0\) \|/);
  // The old per-series dumps are gone.
  assert.doesNotMatch(report, /Deterministic \(allocation & size/);
  assert.doesNotMatch(report, /\| B\/op: /);
  assert.doesNotMatch(report, /\| sample wasm: /);
});

test("tier rows keep the tight ±2% flag", () => {
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  cur.selfcompile.heap_ptr_bytes = 1030;
  const report = render(cur, base);
  assert.match(report, /\| selfcompile \| 1\.01 KiB \(\+3\.00% ⚠️\) \|/);
});

test("a change too small to round is not printed as a signed zero", () => {
  // 858783744 -> 858783740 is a real -0.0000005% change. `-0.00%` would read
  // as "zero, but negative"; the reader cannot tell it from `±0`.
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  base.selfcompile.heap_ptr_bytes = 858783744;
  cur.selfcompile.heap_ptr_bytes = 858783740;
  const report = render(cur, base);
  assert.doesNotMatch(report, /-0\.00%/);
  assert.match(report, /\(−<0\.01%\)/);
  // And the same value on both sides still reads as a clean zero.
  const flat = render(flatSnapshot("current"), flatSnapshot("baseline"));
  assert.match(flat, /\| selfcompile \| 1000 B \(±0\) \|/);
});

test("a representative missing from the snapshot is named, not rendered as flat", () => {
  const cur = flatSnapshot("current");
  delete cur.benches[REP.largeBench];
  delete cur.sizes.samples[REP.smallSample];
  const report = render(cur, flatSnapshot("baseline"));
  assert.match(report, /no value in this snapshot for/);
  assert.match(report, new RegExp(REP.largeBench.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.match(report, /sample fib/);
});

// --- the drift line: what makes one row per tier safe ------------------------

test("drift in an UNRENDERED series is named rather than hidden by the cut", () => {
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  // Neither of these is a rendered representative.
  cur.sizes.cli_adapter_bundle = 1100;
  base.sizes.cli_adapter_bundle = 1000;
  cur.benches["alloc_bench.vibe::build_100"] = { bytes_per_op: 200 };
  base.benches["alloc_bench.vibe::build_100"] = { bytes_per_op: 100 };
  const report = render(cur, base);
  assert.match(report, /drift outside the rows above \(±2% threshold, 2\)/);
  assert.match(report, /cli_adapter_bundle \+10\.00% ⚠️/);
  assert.match(report, /B\/op alloc_bench\.vibe::build_100 \+100\.00% ⚠️/);
});

test("a flat run says so, and says how many series it actually compared", () => {
  const report = render(flatSnapshot("current"), flatSnapshot("baseline"));
  assert.match(report, /no drift ≥±2% in the \d+ other tracked series compared/);
});

// --- lost instrumentation must not read as agreement -------------------------

test("a metric the baseline measured and this run did not is named, not counted clean", () => {
  // `bench_metrics.sh` scrapes fuel/memory out of the runner's stderr, so a
  // scenario that RAN FINE but printed no `vibe::fuel` line is stored as null
  // under an `ok` status. Skipping it (pctOf -> null) and then printing "no
  // drift" claims a clean scan over something never measured.
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  base.exec = execOf({ [REP.medium]: okScenario, other: okScenario });
  cur.exec = execOf({
    [REP.medium]: okScenario,
    other: { ...okScenario, linear: { ...okScenario.linear, fuel: null, heap_bytes: null } },
  });
  const report = render(cur, base);
  assert.match(report, /measured on the baseline, absent here \(2\)/);
  assert.match(report, /other fuel/);
  assert.match(report, /other heap/);
  // and the scan must not describe itself as clean over them
  assert.doesNotMatch(report, /no drift ≥±2% in any other tracked series$/m);
});

test("a representative cell with no value is named even when its scenario is ok", () => {
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  base.exec = execOf({ [REP.medium]: okScenario });
  cur.exec = execOf({ [REP.medium]: { ...okScenario, linear: { ...okScenario.linear, fuel: null } } });
  const report = render(cur, base);
  assert.match(report, /no value in this snapshot for: expr_eval fuel/);
});

test("zero comparable series still says so rather than dropping the line", () => {
  const bare = { commit: "c", selfcompile: { heap_ptr_bytes: 1 }, sizes: {}, benches: {} };
  const report = render(bare, { commit: "b", date: "2026-08-11", selfcompile: { heap_ptr_bytes: 1 }, sizes: {}, benches: {} });
  assert.match(report, /no other tracked series to compare/);
});

test("a rendered representative is not repeated in the drift line", () => {
  const base = flatSnapshot("baseline");
  const cur = flatSnapshot("current");
  cur.selfcompile.heap_ptr_bytes = 1030;
  const report = render(cur, base);
  assert.doesNotMatch(report, /drift outside the rows above/);
  assert.match(report, /no drift ≥±2% in the \d+ other tracked series compared/);
});

// --- exec corpus -------------------------------------------------------------

const okScenario = {
  linear: { status: "ok", fuel: 1000000, heap_bytes: 4096, committed_bytes: 65536, wasm_bytes: 5000 },
  gc: { status: "ok", fuel: 800000, wasm_bytes: 6000, detail: null },
  output: "ok",
};
const execOf = (scen) => ({ status: "ok", wasmtime: "47.0.2", scenarios: scen });

test("the Medium row reads the representative scenario, and the output check survives the cut", () => {
  const cur = flatSnapshot("current");
  const base = flatSnapshot("baseline");
  cur.exec = execOf({ [REP.medium]: okScenario, other: okScenario });
  base.exec = execOf({
    [REP.medium]: { ...okScenario, linear: { ...okScenario.linear, fuel: 900000 } },
    other: okScenario,
  });
  const report = render(cur, base);
  assert.match(report, /\| expr_eval \| 4\.00 KiB \(±0\) \| 4\.88 KiB \(±0\) \| 1\.00M \(\+11\.11% ⚠️\) \|/);
  assert.match(report, /output checks: 2\/2 scenarios ✅/);
});

test("wasmtime version drift omits fuel deltas instead of comparing across cost tables", () => {
  const cur = flatSnapshot("current");
  const base = flatSnapshot("baseline");
  cur.exec = { status: "ok", wasmtime: "48.0.0", scenarios: { [REP.medium]: okScenario } };
  base.exec = { status: "ok", wasmtime: "47.0.2", scenarios: { [REP.medium]: okScenario } };
  const report = render(cur, base);
  assert.match(report, /fuel not comparable to baseline: wasmtime 47\.0\.2 → 48\.0\.0/);
  assert.match(report, /\| expr_eval \| .* \| .* \| 1\.00M \(–\) \|/);
});

test("a parity mismatch is rendered as a loud silent-wrong flag, a gc gap as a note", () => {
  const cur = flatSnapshot("current");
  cur.exec = { status: "partial", wasmtime: "47.0.2", scenarios: {
    bad: { ...okScenario, output: "parity-mismatch" },
    gap: { linear: okScenario.linear,
      gc: { status: "compile-failed", fuel: null, wasm_bytes: null, detail: "GC codegen: unknown constructor or function: Array::map" },
      output: "ok" },
  } };
  const report = render(cur);
  assert.match(report, /❌ \*\*bad: parity-mismatch\*\* — generated code produced WRONG output/);
  assert.match(report, /⚠️ gap: gc compile-failed — GC codegen: unknown constructor or function: Array::map/);
  assert.doesNotMatch(report, /output checks: .* ✅/);
});

// --- coverage ----------------------------------------------------------------

test("coverage leads the report, renders as main's, and degrades when absent", () => {
  withDir((dir) => {
    const minimal = { commit: "x", selfcompile: {}, sizes: {}, benches: {} };
    const curP = join(dir, "current.json");
    writeFileSync(curP, JSON.stringify(minimal));
    const covP = join(dir, "coverage_latest.json");
    writeFileSync(covP, JSON.stringify({
      schema: 1, commit: "covsha1234", date: "2026-08-15T12:00:00Z",
      function_union: { hit: 12950, total: 14995, rate: 86.36 },
      branch_union: { hit: 26442, total: 45986, rate: 57.5, exact: false },
      entries_total: 582, entries_passed: 582, case_rate: 100,
      prev: { commit: "old", date: "2026-08-14T00:00:00Z", function_union_rate: 86.36, branch_union_rate: 57.07 },
    }));
    const withCov = run([curP, join(dir, "missing.json"), covP]);
    assert.match(withCov, /#### Coverage \(selfhost suite — measured on main, not this PR\)/);
    // Coverage comes before the tiers.
    assert.ok(withCov.indexOf("#### Coverage") < withCov.indexOf("#### Large"));
    assert.match(withCov, /\| branch union \| 26,442 \| 45,986 \| 57\.50% \| \+0\.43pt 🎉 \|/);
    assert.match(withCov, /\| function union \| 12,950 \| 14,995 \| 86\.36% \| ±0 \|/);
    assert.match(withCov, /cases 582\/582 \(100%\) · measured at `covsha123` \(2026-08-15\)/);
    assert.match(withCov, /branch union is a LOWER BOUND/);

    const withoutCov = run([curP]);
    assert.doesNotMatch(withoutCov, /Coverage/);

    // A 0-byte optional file (how `git show missing > file` leaves things in
    // the perf workflow) must degrade like an absent one, not crash the
    // report -- the first #1883 CI run died exactly here.
    const emptyBase = join(dir, "empty_base.json");
    const emptyCov = join(dir, "empty_cov.json");
    writeFileSync(emptyBase, "");
    writeFileSync(emptyCov, "");
    const withEmpty = run([curP, emptyBase, emptyCov]);
    assert.doesNotMatch(withEmpty, /Coverage/);
    assert.match(withEmpty, /baseline: _none yet_/);
  });
});
