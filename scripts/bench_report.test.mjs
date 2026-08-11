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

function renderReport({ factor, currentWall, baselineWall = 100 }) {
  const dir = mkdtempSync(join(tmpdir(), "vibe-bench-report-"));
  try {
    const baseline = {
      commit: "baseline",
      date: "2026-08-11",
      selfcompile: { wall_ms_median: baselineWall },
      sizes: {},
      benches: {},
      calibration: { label: "build_100", ns_p50: 10000, ...hashes },
    };
    const current = {
      commit: "current",
      selfcompile: { wall_ms_median: currentWall },
      sizes: {},
      benches: {},
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

function advisoryWallRow(report) {
  return report.split("\n").find((line) => line.startsWith("| selfcompile wall_ms"));
}

test("0.586 runner mismatch fails open to the raw advisory delta", () => {
  const report = renderReport({ factor: 0.586, currentWall: 80 });
  assert.match(report, /runner mismatch: calibration factor 0\.586× is outside the plausible 0\.85–1\.18× range/);
  assert.equal(advisoryWallRow(report), "| selfcompile wall_ms (median) | 80 | 100 | -20.00% 🎉 |");
  assert.doesNotMatch(advisoryWallRow(report), /\(norm\)/);
});

test("0.807 runner mismatch does not turn a flat raw reading into a normalized warning", () => {
  const report = renderReport({ factor: 0.807, currentWall: 100 });
  assert.match(report, /runner mismatch: calibration factor 0\.807×/);
  assert.equal(advisoryWallRow(report), "| selfcompile wall_ms (median) | 100 | 100 | ±0 |");
  assert.doesNotMatch(advisoryWallRow(report), /⚠️|\(norm\)/);
});

test("1.132 plausible factor preserves existing normalized behavior", () => {
  const report = renderReport({ factor: 1.132, currentWall: 120 });
  assert.match(report, /runner factor 1\.132× .* advisory deltas below are normalized/);
  assert.equal(advisoryWallRow(report), "| selfcompile wall_ms (median) | 120 | 100 | +6.01% (norm) |");
});

test("plausible normalization may expose sign disagreement without a false warning", () => {
  const report = renderReport({ factor: 1.132, currentWall: 105 });
  assert.equal(advisoryWallRow(report), "| selfcompile wall_ms (median) | 105 | 100 | -7.24% (norm) |");
  assert.doesNotMatch(advisoryWallRow(report), /⚠️|🎉/);
});

test("plausibility range is inclusive and reports adjacent rejections honestly", () => {
  assert.match(renderReport({ factor: 0.85, currentWall: 100 }), /runner factor 0\.850×/);
  assert.match(renderReport({ factor: 1.18, currentWall: 100 }), /runner factor 1\.180×/);
  assert.match(renderReport({ factor: 0.8499, currentWall: 100 }), /runner mismatch: calibration factor 0\.8499×/);
  assert.match(renderReport({ factor: 1.1801, currentWall: 100 }), /runner mismatch: calibration factor 1\.1801×/);
});
