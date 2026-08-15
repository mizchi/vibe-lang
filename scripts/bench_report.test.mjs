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

// Snapshots deliberately carry advisory wall-time data (wall_ms_median,
// ns_p50) and a calibration record — the report must keep IGNORING them:
// they live in the bench-data history only (runner-speed noise, #1207/#1209).
function renderReport({ factor, currentWall, baselineWall = 100 }) {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-"));
  try {
    const baseline = {
      commit: "baseline",
      date: "2026-08-11",
      selfcompile: { heap_ptr_bytes: 1000, wall_ms_median: baselineWall },
      sizes: {},
      benches: { "b.vibe::case": { ns_p50: 5000, bytes_per_op: 64 } },
      calibration: { label: "build_100", ns_p50: 10000, ...hashes },
    };
    const current = {
      commit: "current",
      selfcompile: { heap_ptr_bytes: 1000, wall_ms_median: currentWall },
      sizes: {},
      benches: { "b.vibe::case": { ns_p50: 9000, bytes_per_op: 64 } },
      calibration: { label: "build_100", ns_p50: Math.round(factor * 10000), ...hashes },
    };
    const currentPath = join(dir, "current.json");
    const baselinePath = join(dir, "baseline.json");
    writeFileSync(currentPath, JSON.stringify(current));
    writeFileSync(baselinePath, JSON.stringify(baseline));
    const result = spawnSync(process.execPath, [reportScript.pathname, currentPath, baselinePath], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("advisory wall-time and calibration data are never rendered", () => {
  // Wildly different wall readings and an implausible calibration factor must
  // leave zero trace in the report — no wall rows, no ns/op rows, no
  // calibration notes, no advisory section at all.
  for (const args of [
    { factor: 0.586, currentWall: 80 },
    { factor: 1.132, currentWall: 500 },
  ]) {
    const report = renderReport(args);
    // The footer legitimately mentions where the unrendered data lives —
    // exclude it, then require zero advisory traces in the body.
    const body = report.split("\n").filter((l) => !l.startsWith("<sub>")).join("\n");
    assert.doesNotMatch(body, /wall_ms|ns\/op|Advisory|calibration|runner factor|runner mismatch|<details>/);
    // The deterministic view of the same tracked bench still renders.
    assert.match(report, /\| B\/op: b\.vibe::case \| 64 B \| 64 B \| ±0 \|/);
    // The footer says where the unrendered advisory data lives.
    assert.match(report, /wall times & runner calibration: recorded in the `bench-data` snapshots, not rendered/);
  }
});

test("deterministic rows keep the tight ±2% flag", () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-det-"));
  try {
    const mk = (heap) => ({
      commit: "x",
      selfcompile: { heap_ptr_bytes: heap },
      sizes: {},
      benches: {},
    });
    const currentPath = join(dir, "current.json");
    const baselinePath = join(dir, "baseline.json");
    writeFileSync(currentPath, JSON.stringify(mk(1030)));
    writeFileSync(baselinePath, JSON.stringify(mk(1000)));
    const result = spawnSync(process.execPath, [reportScript.pathname, currentPath, baselinePath], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /\| selfcompile heap_ptr_bytes \| 1\.01 KiB \| 1000 B \| \+3\.00% ⚠️ \|/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// --- exec corpus section (deterministic fuel / memory / parity) ---------------

function renderExecReport({ curExec, baseExec }) {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-exec-"));
  try {
    const shared = {
      selfcompile: { wall_ms_median: 100 },
      sizes: {},
      benches: {},
      calibration: { label: "build_100", ns_p50: 10000, ...hashes },
    };
    const current = { commit: "current", ...shared, exec: curExec };
    const currentPath = join(dir, "current.json");
    writeFileSync(currentPath, JSON.stringify(current));
    const args = [reportScript.pathname, currentPath];
    if (baseExec !== undefined) {
      const baseline = { commit: "baseline", date: "2026-08-11", ...shared, exec: baseExec };
      const baselinePath = join(dir, "baseline.json");
      writeFileSync(baselinePath, JSON.stringify(baseline));
      args.push(baselinePath);
    }
    const result = spawnSync(process.execPath, args, { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const okScenario = {
  linear: { status: "ok", fuel: 1000000, heap_bytes: 4096, committed_bytes: 65536, wasm_bytes: 5000 },
  gc: { status: "ok", fuel: 800000, wasm_bytes: 6000, detail: null },
  output: "ok",
};

test("exec section renders fuel deltas, gc ratio, and the all-ok output line", () => {
  const cur = { status: "ok", wasmtime: "47.0.2", scenarios: { demo: okScenario } };
  const base = { status: "ok", wasmtime: "47.0.2", scenarios: {
    demo: { ...okScenario, linear: { ...okScenario.linear, fuel: 900000 } },
  } };
  const report = renderExecReport({ curExec: cur, baseExec: base });
  assert.match(report, /Program execution \(deterministic/);
  assert.match(report, /\| demo \| 1\.00M \| \+11\.11% ⚠️ \| 800k \| ±0 \| 0\.80× \|/);
  assert.match(report, /\| demo \| 4\.00 KiB \| ±0 \| 64\.0 KiB \| ±0 \| 4\.88 KiB \| ±0 \| 5\.86 KiB \| ±0 \|/);
  assert.match(report, /output checks: 1\/1 scenarios ✅/);
});

test("wasmtime version drift omits fuel deltas instead of comparing across cost tables", () => {
  const cur = { status: "ok", wasmtime: "48.0.0", scenarios: { demo: okScenario } };
  const base = { status: "ok", wasmtime: "47.0.2", scenarios: { demo: okScenario } };
  const report = renderExecReport({ curExec: cur, baseExec: base });
  assert.match(report, /fuel not comparable to baseline: wasmtime 47\.0\.2 → 48\.0\.0/);
  assert.match(report, /\| demo \| 1\.00M \| – \| 800k \| – \| 0\.80× \|/);
});

// --- test-coverage section (bench-data coverage snapshot, main-only) ----------

test("coverage snapshot renders as main's coverage with a pt trend, absent when no snapshot", () => {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-cov-"));
  try {
    const minimal = { commit: "x", selfcompile: {}, sizes: {}, benches: {} };
    const currentPath = join(dir, "current.json");
    writeFileSync(currentPath, JSON.stringify(minimal));
    const covPath = join(dir, "coverage_latest.json");
    writeFileSync(covPath, JSON.stringify({
      schema: 1, commit: "covsha1234", date: "2026-08-15T12:00:00Z",
      function_union: { hit: 12950, total: 14995, rate: 86.36 },
      branch_union: { hit: 26442, total: 45986, rate: 57.5, exact: false },
      entries_total: 582, entries_passed: 582, case_rate: 100,
      prev: { commit: "old", date: "2026-08-14T00:00:00Z", function_union_rate: 86.36, branch_union_rate: 57.07 },
    }));
    const withCov = spawnSync(process.execPath,
      [reportScript.pathname, currentPath, join(dir, "missing.json"), covPath], { encoding: "utf8" });
    assert.equal(withCov.status, 0, withCov.stderr);
    assert.match(withCov.stdout, /#### Test coverage \(selfhost suite — measured on main, not this PR\)/);
    assert.match(withCov.stdout, /\| branch union \| 26,442 \| 45,986 \| 57\.50% \| \+0\.43pt 🎉 \|/);
    assert.match(withCov.stdout, /\| function union \| 12,950 \| 14,995 \| 86\.36% \| ±0 \|/);
    assert.match(withCov.stdout, /cases 582\/582 \(100%\) · measured at `covsha123` \(2026-08-15\)/);
    assert.match(withCov.stdout, /branch union is a LOWER BOUND/);

    const withoutCov = spawnSync(process.execPath,
      [reportScript.pathname, currentPath], { encoding: "utf8" });
    assert.equal(withoutCov.status, 0, withoutCov.stderr);
    assert.doesNotMatch(withoutCov.stdout, /Test coverage/);

    // A 0-byte optional file (how `git show missing > file` leaves things in
    // the perf workflow) must degrade like an absent one, not crash the
    // report — the first #1883 CI run died exactly here.
    const emptyBase = join(dir, "empty_base.json");
    const emptyCov = join(dir, "empty_cov.json");
    writeFileSync(emptyBase, "");
    writeFileSync(emptyCov, "");
    const withEmpty = spawnSync(process.execPath,
      [reportScript.pathname, currentPath, emptyBase, emptyCov], { encoding: "utf8" });
    assert.equal(withEmpty.status, 0, withEmpty.stderr);
    assert.doesNotMatch(withEmpty.stdout, /Test coverage/);
    assert.match(withEmpty.stdout, /baseline: _none yet_/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a parity mismatch is rendered as a loud silent-wrong flag, a gc gap as a note", () => {
  const cur = { status: "partial", wasmtime: "47.0.2", scenarios: {
    bad: { ...okScenario, output: "parity-mismatch" },
    gap: { linear: okScenario.linear,
      gc: { status: "compile-failed", fuel: null, wasm_bytes: null, detail: "GC codegen: unknown constructor or function: Array::map" },
      output: "ok" },
  } };
  const report = renderExecReport({ curExec: cur });
  assert.match(report, /❌ \*\*bad: parity-mismatch\*\* — generated code produced WRONG output/);
  assert.match(report, /⚠️ gap: gc compile-failed — GC codegen: unknown constructor or function: Array::map/);
  assert.doesNotMatch(report, /output checks: .* ✅/);
});
