#!/usr/bin/env node
// Render the perf-tracking markdown report from bench_metrics.sh snapshots.
//
//   node scripts/bench_report.mjs current.json [baseline.json]
//
// The report renders DETERMINISTIC metrics only (heap, sizes, bytes/op, exec
// fuel/memory/parity): any change is real, >±2% gets a warning emoji. The
// snapshots also carry advisory wall-time readings (wall_ms, ns_p50) and the
// runner calibration record — those stay in the bench-data history for
// offline analysis but are deliberately NOT rendered: shared-runner speed
// swings every wall row ±15-40% on unrelated PRs (see the #1207/#1209
// postmortems and bench/perf/README.md "Runner normalization"), which made
// the section noise for human AND LLM readers alike. Never exits non-zero on
// regressions: this is a report, the blocking gate for allocation is ci.yml's
// KPI heap step.
import { readFileSync, existsSync } from "node:fs";

const [curPath, basePath] = process.argv.slice(2);
if (!curPath) {
  console.error("usage: bench_report.mjs current.json [baseline.json]");
  process.exit(2);
}
const cur = JSON.parse(readFileSync(curPath, "utf8"));
const base = basePath && existsSync(basePath) ? JSON.parse(readFileSync(basePath, "utf8")) : null;

// Human-readable units for table cells. Rounding here loses no signal: the Δ
// column is computed from the raw values, so "any drift is real" still reads
// off the percentage even when two close values render the same.
const nice = (v) => v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
const fmtBytes = (n) => {
  if (n == null) return "–";
  if (n < 1024) return `${n} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${nice(v)} ${units[i]}`;
};
// Fuel = executed-instruction count; k/M/G are decimal. Small counts stay raw.
const fmtCount = (n) => {
  if (n == null) return "–";
  if (n < 10000) return n.toLocaleString("en-US");
  const units = ["k", "M", "G"];
  let v = n / 1000, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i += 1; }
  return `${nice(v)}${units[i]}`;
};

function delta(curV, baseV) {
  if (baseV == null || curV == null) return " | –";
  if (baseV === curV) return " | ±0";
  const pct = baseV === 0 ? 100 : ((curV - baseV) / baseV) * 100;
  const sign = pct > 0 ? "+" : "";
  const flag = Math.abs(pct) >= 2 ? (pct > 0 ? " ⚠️" : " 🎉") : "";
  return ` | ${sign}${pct.toFixed(2)}%${flag}`;
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
for (const [name, c, b] of detRows) lines.push(`| ${name} | ${fmtBytes(c)} | ${fmtBytes(b)}${delta(c, b)} |`);
for (const [name, c] of Object.entries(cur.sizes?.samples || {})) {
  const b = base?.sizes?.samples?.[name];
  lines.push(`| sample wasm: ${name} | ${fmtBytes(c)} | ${fmtBytes(b)}${delta(c, b)} |`);
}
for (const [label, v] of Object.entries(cur.benches || {})) {
  const b = base?.benches?.[label]?.bytes_per_op;
  lines.push(`| B/op: ${label} | ${fmtBytes(v.bytes_per_op)} | ${fmtBytes(b)}${delta(v.bytes_per_op, b)} |`);
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
    const dLin = fuelComparable ? delta(s.linear?.fuel, b?.linear?.fuel).replace(" | ", "") : "–";
    const dGc = fuelComparable ? delta(s.gc?.fuel, b?.gc?.fuel).replace(" | ", "") : "–";
    lines.push(`| ${name} | ${fmtCount(s.linear?.fuel)} | ${dLin} | ${fmtCount(s.gc?.fuel)} | ${dGc} | ${ratio(s.gc?.fuel, s.linear?.fuel)} |`);
  }
  lines.push("");
  lines.push("| scenario | heap | Δ | committed | Δ | wasm (linear) | Δ | wasm (gc) | Δ |");
  lines.push("|---|---:|---|---:|---|---:|---|---:|---|");
  for (const [name, s] of Object.entries(execCur.scenarios)) {
    const b = execBase?.scenarios?.[name];
    const d = (c, bb) => delta(c, bb).replace(" | ", "");
    lines.push(`| ${name} | ${fmtBytes(s.linear?.heap_bytes)} | ${d(s.linear?.heap_bytes, b?.linear?.heap_bytes)} | ${fmtBytes(s.linear?.committed_bytes)} | ${d(s.linear?.committed_bytes, b?.linear?.committed_bytes)} | ${fmtBytes(s.linear?.wasm_bytes)} | ${d(s.linear?.wasm_bytes, b?.linear?.wasm_bytes)} | ${fmtBytes(s.gc?.wasm_bytes)} | ${d(s.gc?.wasm_bytes, b?.gc?.wasm_bytes)} |`);
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

if (cur.micro_status && cur.micro_status !== "ok") {
  lines.push(`> micro benches: ${cur.micro_status}`);
  lines.push("");
}
lines.push(`<sub>wall times & runner calibration: recorded in the \`bench-data\` snapshots, not rendered (runner-speed noise — see bench/perf/README.md) · tracked series: bench/perf/tracked_benches.txt · docs: bench/perf/README.md</sub>`);

console.log(lines.join("\n"));
