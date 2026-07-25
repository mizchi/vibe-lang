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
function delta(curV, baseV, loosePct) {
  if (baseV == null || curV == null) return " | –";
  if (baseV === curV) return " | ±0";
  const pct = baseV === 0 ? 100 : ((curV - baseV) / baseV) * 100;
  const sign = pct > 0 ? "+" : "";
  const flagAt = loosePct ? 15 : 2;
  const flag = Math.abs(pct) >= flagAt ? (pct > 0 ? " ⚠️" : " 🎉") : "";
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

lines.push("#### Advisory (wall time — CI noise ±10-15% is normal)");
lines.push("");
lines.push("| metric | current | baseline | Δ |");
lines.push("|---|---:|---:|---|");
lines.push(`| selfcompile wall_ms (median) | ${fmt(cur.selfcompile?.wall_ms_median)} | ${fmt(base?.selfcompile?.wall_ms_median)}${delta(cur.selfcompile?.wall_ms_median, base?.selfcompile?.wall_ms_median, true)} |`);
for (const [label, v] of Object.entries(cur.benches || {})) {
  const b = base?.benches?.[label]?.ns_p50;
  lines.push(`| ns/op p50: ${label} | ${fmt(v.ns_p50)} | ${fmt(b)}${delta(v.ns_p50, b, true)} |`);
}
lines.push("");
if (cur.micro_status && cur.micro_status !== "ok") {
  lines.push(`> micro benches: ${cur.micro_status}`);
  lines.push("");
}
lines.push(`<sub>tracked series: bench/perf/tracked_benches.txt · history: \`bench-data\` branch · docs: bench/perf/README.md</sub>`);

console.log(lines.join("\n"));
