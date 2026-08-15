#!/usr/bin/env node
// Render the perf-tracking markdown report from bench_metrics.sh snapshots.
//
//   node scripts/bench_report.mjs current.json [baseline.json]
//
// DETERMINISTIC metrics (heap, sizes, bytes/op) get a tight flag threshold
// (any change is real; >±2% gets a warning emoji). ADVISORY wall-time
// metrics (wall_ms, ns_p50) flag only past ±15% — CI runners are noisy.
// Never exits non-zero on regressions: this is a report, the blocking gate
// for allocation is ci.yml's KPI heap step.
import { readFileSync, existsSync } from "node:fs";

const [curPath, basePath] = process.argv.slice(2);
if (!curPath) {
  console.error("usage: bench_report.mjs current.json [baseline.json]");
  process.exit(2);
}
const cur = JSON.parse(readFileSync(curPath, "utf8"));
const base = basePath && existsSync(basePath) ? JSON.parse(readFileSync(basePath, "utf8")) : null;

const fmt = (n) => n == null ? "–" : n.toLocaleString("en-US");

// Runner normalization (see scripts/bench_metrics.sh header for rationale):
// shared CI runners vary in raw speed run to run, which shows up as every
// single advisory metric moving together by a similar magnitude — the
// #1207 investigation caught two unrelated PRs each showing a uniform
// swing in opposite directions, neither caused by the PR's own code. Both
// snapshots also bench a fixed already-tracked series against the
// COMMITTED SEED wasm; the ratio of those two readings estimates how much
// faster/slower THIS runner is right now vs. when the baseline was taken,
// so advisory deltas can be corrected for it instead of read at face value.
//
// The calibration reading is only pure "runner speed" if every input that
// feeds it is unchanged: the seed wasm, the viberun runner binary (built
// from the current checkout), AND the calibration bench source itself
// (also read from the current checkout). A PR that changes runtime/viberun
// or bench/regression/alloc_bench.vibe would otherwise have that real
// change misread as host-speed drift and divided out of every advisory
// delta (found in review, #1209) — so all three hashes must be present
// and equal on both snapshots before normalizing.
const RUNNER_FACTOR_MIN = 0.85;
const RUNNER_FACTOR_MAX = 1.18;
let runnerFactor = null;
let calibNote = "no calibration data (older baseline snapshot, or runner/seed unavailable) — deltas below are raw, uncorrected for runner speed";
{
  const c = cur.calibration, b = base?.calibration;
  if (c?.ns_p50 != null && b?.ns_p50 != null) {
    const hashFields = ["seed_sha256", "runner_sha256", "bench_sha256"];
    const missing = hashFields.filter((k) => !c[k] || !b[k]);
    const mismatched = hashFields.filter((k) => c[k] && b[k] && c[k] !== b[k]);
    if (missing.length) {
      calibNote = `calibration inputs not recorded on both snapshots (missing: ${missing.join(", ")}) — not comparable, deltas below are raw`;
    } else if (mismatched.length) {
      calibNote = `calibration inputs changed between baseline and current (${mismatched.join(", ")}) — not comparable (bootstrap bump, or a change to runtime/viberun or the calibration bench), deltas below are raw`;
    } else if (b.ns_p50 > 0) {
      const candidateFactor = c.ns_p50 / b.ns_p50;
      const reading = `${c.label || "calibration"}: current ${fmt(c.ns_p50)}ns vs baseline ${fmt(b.ns_p50)}ns p50`;
      if (candidateFactor >= RUNNER_FACTOR_MIN && candidateFactor <= RUNNER_FACTOR_MAX) {
        runnerFactor = candidateFactor;
        calibNote = `runner factor ${runnerFactor.toFixed(3)}× (${reading}) — advisory deltas below are normalized to correct for it`;
      } else {
        calibNote = `runner mismatch: calibration factor ${String(candidateFactor)}× is outside the plausible ${RUNNER_FACTOR_MIN.toFixed(2)}–${RUNNER_FACTOR_MAX.toFixed(2)}× range (${reading}) — advisory deltas below are raw`;
      }
    }
  }
}

function delta(curV, baseV, loosePct, normalize) {
  if (baseV == null || curV == null) return " | –";
  const adjCurV = normalize && runnerFactor ? curV / runnerFactor : curV;
  if (baseV === adjCurV) return " | ±0";
  const pct = baseV === 0 ? 100 : ((adjCurV - baseV) / baseV) * 100;
  const sign = pct > 0 ? "+" : "";
  const flagAt = loosePct ? 15 : 2;
  const flag = Math.abs(pct) >= flagAt ? (pct > 0 ? " ⚠️" : " 🎉") : "";
  const tag = normalize && runnerFactor ? " (norm)" : "";
  return ` | ${sign}${pct.toFixed(2)}%${flag}${tag}`;
}

const lines = [];
lines.push("<!-- vibe-perf-report -->");
lines.push(`### 📊 Perf report`);
lines.push("");
lines.push(`current: \`${(cur.commit || "?").slice(0, 9)}\`` +
  (base ? ` / baseline (main): \`${(base.commit || "?").slice(0, 9)}\` (${(base.date || "").slice(0, 10)})` : " / baseline: _none yet_"));
lines.push("");

lines.push("#### Deterministic (allocation & size — any drift is real)");
lines.push("");
lines.push("| metric | current | baseline | Δ |");
lines.push("|---|---:|---:|---|");
const detRows = [
  ["selfcompile heap_ptr_bytes", cur.selfcompile?.heap_ptr_bytes, base?.selfcompile?.heap_ptr_bytes],
  ["stage2.wasm bytes", cur.sizes?.stage2_wasm, base?.sizes?.stage2_wasm],
  ["cli_adapter_bundle bytes", cur.sizes?.cli_adapter_bundle, base?.sizes?.cli_adapter_bundle],
  ["compiler_sources_bundle bytes", cur.sizes?.compiler_sources_bundle, base?.sizes?.compiler_sources_bundle],
  ["flat module source bytes", cur.sizes?.module_source, base?.sizes?.module_source],
];
for (const [name, c, b] of detRows) lines.push(`| ${name} | ${fmt(c)} | ${fmt(b)}${delta(c, b, false)} |`);
for (const [name, c] of Object.entries(cur.sizes?.samples || {})) {
  const b = base?.sizes?.samples?.[name];
  lines.push(`| sample wasm: ${name} | ${fmt(c)} | ${fmt(b)}${delta(c, b, false)} |`);
}
for (const [label, v] of Object.entries(cur.benches || {})) {
  const b = base?.benches?.[label]?.bytes_per_op;
  lines.push(`| B/op: ${label} | ${fmt(v.bytes_per_op)} | ${fmt(b)}${delta(v.bytes_per_op, b, false)} |`);
}
lines.push("");

// Program execution: fuel (deterministic instruction-count proxy), memory and
// linear-vs-wasm-gc comparison over the general-program corpus (bench/exec/).
// Fuel readings are only comparable when both snapshots metered on the same
// wasmtime version — the per-instruction cost table lives in wasmtime.
const execCur = cur.exec;
const execBase = base?.exec;
if (execCur?.scenarios && Object.keys(execCur.scenarios).length) {
  lines.push("#### Program execution (deterministic — fuel, memory, linear vs wasm-gc)");
  lines.push("");
  let fuelComparable = true;
  if (execBase?.scenarios && execCur.wasmtime && execBase.wasmtime &&
      execCur.wasmtime !== execBase.wasmtime) {
    fuelComparable = false;
    lines.push(`> fuel not comparable to baseline: wasmtime ${execBase.wasmtime} → ${execCur.wasmtime} (per-instruction cost table changed) — fuel Δ omitted`);
    lines.push("");
  }
  const ratio = (g, l) => (g != null && l != null && l > 0) ? `${(g / l).toFixed(2)}×` : "–";
  lines.push("| scenario | fuel (linear) | Δ | fuel (gc) | Δ | gc÷linear |");
  lines.push("|---|---:|---|---:|---|---|");
  for (const [name, s] of Object.entries(execCur.scenarios)) {
    const b = execBase?.scenarios?.[name];
    const dLin = fuelComparable ? delta(s.linear?.fuel, b?.linear?.fuel, false).replace(" | ", "") : "–";
    const dGc = fuelComparable ? delta(s.gc?.fuel, b?.gc?.fuel, false).replace(" | ", "") : "–";
    lines.push(`| ${name} | ${fmt(s.linear?.fuel)} | ${dLin} | ${fmt(s.gc?.fuel)} | ${dGc} | ${ratio(s.gc?.fuel, s.linear?.fuel)} |`);
  }
  lines.push("");
  lines.push("| scenario | heap bytes | Δ | wasm bytes (linear) | Δ | wasm bytes (gc) | Δ |");
  lines.push("|---|---:|---|---:|---|---:|---|");
  for (const [name, s] of Object.entries(execCur.scenarios)) {
    const b = execBase?.scenarios?.[name];
    const d = (c, bb) => delta(c, bb, false).replace(" | ", "");
    lines.push(`| ${name} | ${fmt(s.linear?.heap_bytes)} | ${d(s.linear?.heap_bytes, b?.linear?.heap_bytes)} | ${fmt(s.linear?.wasm_bytes)} | ${d(s.linear?.wasm_bytes, b?.linear?.wasm_bytes)} | ${fmt(s.gc?.wasm_bytes)} | ${d(s.gc?.wasm_bytes, b?.gc?.wasm_bytes)} |`);
  }
  lines.push("");
  // Correctness lines: golden (linear vs committed expected output) and
  // backend parity (gc vs linear stdout). A mismatch is a silent-wrong
  // candidate — the loudest thing in this report by design.
  const names = Object.entries(execCur.scenarios);
  const bad = names.filter(([, s]) => s.output !== "ok" && s.output !== "skipped");
  const gcGaps = names.filter(([, s]) => s.gc?.status && s.gc.status !== "ok");
  const linBroken = names.filter(([, s]) => s.linear?.status && s.linear.status !== "ok");
  if (!bad.length && !linBroken.length) {
    const ran = names.filter(([, s]) => s.output === "ok").length;
    lines.push(`> output checks: ${ran}/${names.length} scenarios ✅ (linear = golden; gc = linear where the gc lane runs)` +
      (gcGaps.length ? ` — ${gcGaps.length} gc-lane gap${gcGaps.length > 1 ? "s" : ""} below` : ""));
  }
  for (const [name, s] of linBroken) {
    lines.push(`> ❌ **${name}: linear ${s.linear.status}** — the corpus program no longer compiles/runs`);
  }
  for (const [name, s] of bad) {
    lines.push(`> ❌ **${name}: ${s.output}** — generated code produced WRONG output (silent-wrong candidate, investigate before merging)`);
  }
  for (const [name, s] of gcGaps) {
    lines.push(`> ⚠️ ${name}: gc ${s.gc.status}${s.gc.detail ? ` — ${s.gc.detail}` : ""}`);
  }
  lines.push("");
  if (execCur.status && execCur.status !== "ok" && execCur.status !== "partial") {
    lines.push(`> exec scenarios: ${execCur.status}`);
    lines.push("");
  }
}

// Advisory wall times are noisy on shared runners even after calibration —
// keep them, but collapsed, so the deterministic sections above are what a
// reviewer reads first.
lines.push("<details>");
lines.push("<summary>Advisory (wall time — CI noise ±10-15% is normal, expand for details)</summary>");
lines.push("");
if (base) {
  lines.push(`> ${calibNote}`);
  lines.push("");
}
lines.push("| metric | current | baseline | Δ |");
lines.push("|---|---:|---:|---|");
lines.push(`| selfcompile wall_ms (median) | ${fmt(cur.selfcompile?.wall_ms_median)} | ${fmt(base?.selfcompile?.wall_ms_median)}${delta(cur.selfcompile?.wall_ms_median, base?.selfcompile?.wall_ms_median, true, true)} |`);
for (const [label, v] of Object.entries(cur.benches || {})) {
  const b = base?.benches?.[label]?.ns_p50;
  lines.push(`| ns/op p50: ${label} | ${fmt(v.ns_p50)} | ${fmt(b)}${delta(v.ns_p50, b, true, true)} |`);
}
lines.push("");
lines.push("</details>");
lines.push("");
if (cur.micro_status && cur.micro_status !== "ok") {
  lines.push(`> micro benches: ${cur.micro_status}`);
  lines.push("");
}
lines.push(`<sub>tracked series: bench/perf/tracked_benches.txt · history: \`bench-data\` branch · docs: bench/perf/README.md</sub>`);

console.log(lines.join("\n"));
