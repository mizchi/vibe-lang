import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const script = new URL("./coverage_bench_snapshot.mjs", import.meta.url);

const suiteReport = {
  cases: [],
  function_union: { hit: 12950, total: 14995, rate: 86.36 },
  branch_union: { hit: 26442, total: 45986, rate: 57.5, exact: true },
  entry_weighted: {},
  entries_total: 582,
  entries_passed: 582,
  case_rate: 100.0,
};

function run(reportDoc, prevDoc, { rawPrev } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "vibe-cov-snap-"));
  try {
    const reportPath = join(dir, "report.json");
    writeFileSync(reportPath, JSON.stringify(reportDoc));
    const args = [script.pathname, reportPath];
    if (prevDoc !== undefined) {
      const prevPath = join(dir, "prev.json");
      writeFileSync(prevPath, rawPrev ? prevDoc : JSON.stringify(prevDoc));
      args.push(prevPath);
    }
    return spawnSync(process.execPath, args, {
      encoding: "utf8",
      env: { ...process.env, GITHUB_SHA: "abc123def456" },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("extracts union metrics and embeds the previous snapshot's rates as prev", () => {
  const prev = {
    commit: "prevsha", date: "2026-08-14T00:00:00Z",
    function_union: { hit: 1, total: 2, rate: 86.0 },
    branch_union: { hit: 1, total: 2, rate: 57.07 },
  };
  const r = run(suiteReport, prev);
  assert.equal(r.status, 0, r.stderr);
  const doc = JSON.parse(r.stdout);
  assert.equal(doc.commit, "abc123def456");
  assert.deepEqual(doc.branch_union, { hit: 26442, total: 45986, rate: 57.5, exact: true });
  assert.deepEqual(doc.function_union, { hit: 12950, total: 14995, rate: 86.36 });
  assert.equal(doc.entries_passed, 582);
  assert.deepEqual(doc.prev, {
    commit: "prevsha", date: "2026-08-14T00:00:00Z",
    function_union_rate: 86.0, branch_union_rate: 57.07,
  });
});

test("no previous snapshot → prev is null", () => {
  const r = run(suiteReport);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).prev, null);
});

test("a corrupt previous snapshot degrades to prev null instead of blocking the run", () => {
  const r = run(suiteReport, "{ not json", { rawPrev: true });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(JSON.parse(r.stdout).prev, null);
});

test("a suite report without usable union metrics is refused, not emitted partially", () => {
  const broken = { ...suiteReport, branch_union: { rate: 57.5 } };
  const r = run(broken);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /no usable branch_union/);
});
