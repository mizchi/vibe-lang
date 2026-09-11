#!/usr/bin/env node
// Render the perf-tracking markdown report from bench_metrics.sh snapshots.
//
//   node scripts/bench_report.mjs current.json [baseline.json] [coverage.json]
//
// FOUR sections, in this order: coverage, then one per SIZE TIER -- Large the
// compiler itself, Medium a real program, Small a micro case -- with the axes
// (memory, code size, benchmark) as columns. One representative row per tier.
//
// The shape is deliberate. The report used to render every tracked series:
// 5 deterministic rows + 5 sample sizes + 15 B/op rows + 9 exec scenarios
// across two tables + coverage, ~50 rows, of which ~48 read `±0` on an
// ordinary PR. A reader -- human or LLM -- cannot find the one row that moved
// in that, so the report was skipped rather than read, which is worse than a
// smaller report that is actually looked at.
//
// Cutting to one row per tier would create a blind spot on its own, so it does
// not: `driftOutsideRows` below re-checks EVERY tracked metric, rendered or
// not, and names the ones past the ±2% threshold. Flat runs stay small; a
// regression in an unrendered series still shows up by name.
//
// Deltas are rendered INSIDE each cell rather than in one trailing Δ column:
// with three metric columns per row, a single Δ cannot say which metric moved.
//
// Snapshots also carry advisory wall-time readings (wall_ms, ns_p50) and the
// runner calibration record -- those stay in the bench-data history for
// offline analysis but are deliberately NOT rendered: shared-runner speed
// swings every wall row ±15-40% on unrelated PRs (see the #1207/#1209
// postmortems and bench/perf/README.md "Runner normalization"). Never exits
// non-zero on regressions: this is a report, the blocking gate for allocation
// is ci.yml's KPI heap step.
import { readFileSync, existsSync } from "node:fs";

const [curPath, basePath, covPath] = process.argv.slice(2);
if (!curPath) {
  console.error("usage: bench_report.mjs current.json [baseline.json] [coverage.json]");
  process.exit(2);
}
const cur = JSON.parse(readFileSync(curPath, "utf8"));
// Optional inputs degrade to null instead of killing the report: the perf
// workflow materializes them with `git show ... > file || true`, which leaves
// a 0-byte file when the object doesn't exist on bench-data yet (exactly how
// the first #1883 run died: JSON.parse("") on the not-yet-recorded coverage
// snapshot).
const readJsonMaybe = (p) => {
  if (!p || !existsSync(p)) return null;
  try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; }
};
const base = readJsonMaybe(basePath);
// Coverage snapshot from the bench-data branch (scripts/coverage_bench_snapshot.mjs,
// appended by ci.yml's main-only coverage-suite job). Optional; absent until
// the first main run lands one.
const cov = readJsonMaybe(covPath);

// The representative of each tier, BY NAME. Fixed rather than computed (say,
// "the scenario with the most fuel"), because a series whose subject changes
// when the data changes is not a series: the row would silently start
// describing a different program and its Δ would be meaningless. Changing one
// of these is a deliberate edit, and the drift line below still covers
// everything that is not named here.
//
//   Large   the compiler compiling itself -- the only workload at this scale
//   Medium  expr_eval: the corpus's heaviest by fuel (~2.5x the next), an
//           evaluator loop, so the most sensitive to a codegen regression
//   Small   fib / fib30: the smallest thing that still allocates nothing
const REPRESENTATIVE = {
  largeBench: "parser_bench.vibe::parse_checker_vibe",
  medium: "expr_eval",
  smallSample: "fib",
  smallBench: "pure_bench.vibe::fib30",
};

// Human-readable units for table cells. Rounding here loses no signal: the
// delta is computed from the raw values, so "any drift is real" still reads
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

const pctOf = (curV, baseV) => {
  if (baseV == null || curV == null) return null;
  if (baseV === curV) return 0;
  return baseV === 0 ? 100 : ((curV - baseV) / baseV) * 100;
};
const fmtPct = (pct) => {
  if (pct == null) return "–";
  if (pct === 0) return "±0";
  const flag = Math.abs(pct) >= 2 ? (pct > 0 ? " ⚠️" : " 🎉") : "";
  // A real change that rounds to 0.00 must not print as `-0.00%`, which reads
  // as "zero, but negative" -- the values DID differ and two decimals cannot
  // show it. Say that instead of rendering a signed zero.
  if (Math.abs(pct) < 0.005) return `${pct > 0 ? "+" : "−"}<0.01%`;
  return `${pct > 0 ? "+" : ""}${pct.toFixed(2)}%${flag}`;
};
// One cell: the value with its own delta. `comparable=false` renders the value
// with a "–" delta (fuel across a wasmtime cost-table change).
const cell = (fmt, curV, baseV, comparable = true) =>
  `${fmt(curV)} (${comparable ? fmtPct(pctOf(curV, baseV)) : "–"})`;

const lines = [];
lines.push("<!-- vibe-perf-report -->");
lines.push(`### 📊 Perf report`);
lines.push("");
lines.push(`current: \`${(cur.commit || "?").slice(0, 9)}\`` +
  (base ? ` / baseline (main): \`${(base.commit || "?").slice(0, 9)}\` (${(base.date || "").slice(0, 10)})` : " / baseline: _none yet_"));
lines.push("");

// --- coverage ----------------------------------------------------------------
// First, because it is the only section that answers "is the suite still
// looking at the code" rather than "did a number move". Measured by ci.yml's
// main-only coverage-suite job (the suite re-runs the whole battery
// instrumented, too expensive per PR), so it is labelled as main's coverage
// and never this PR's: implying otherwise would be silently wrong. The Δ is
// percentage POINTS against the previous main measurement -- a trend, not a
// baseline-vs-PR diff.
if (cov?.function_union && cov?.branch_union) {
  lines.push("#### Coverage (selfhost suite — measured on main, not this PR)");
  lines.push("");
  const fmtInt = (n) => n == null ? "–" : n.toLocaleString("en-US");
  const rate = (r) => r == null ? "–" : `${Number(r).toFixed(2)}%`;
  const trend = (curR, prevR) => {
    if (curR == null || prevR == null) return "–";
    const pt = curR - prevR;
    if (Math.abs(pt) < 0.005) return "±0";
    const flag = pt <= -0.1 ? " ⚠️" : pt >= 0.1 ? " 🎉" : "";
    return `${pt > 0 ? "+" : ""}${pt.toFixed(2)}pt${flag}`;
  };
  lines.push("| metric | hit | total | rate | Δ vs prev main |");
  lines.push("|---|---:|---:|---:|---|");
  lines.push(`| branch union | ${fmtInt(cov.branch_union.hit)} | ${fmtInt(cov.branch_union.total)} | ${rate(cov.branch_union.rate)} | ${trend(cov.branch_union.rate, cov.prev?.branch_union_rate)} |`);
  lines.push(`| function union | ${fmtInt(cov.function_union.hit)} | ${fmtInt(cov.function_union.total)} | ${rate(cov.function_union.rate)} | ${trend(cov.function_union.rate, cov.prev?.function_union_rate)} |`);
  lines.push("");
  const caseLine = (cov.entries_passed != null && cov.entries_total != null)
    ? `cases ${cov.entries_passed}/${cov.entries_total}` + (cov.case_rate != null ? ` (${cov.case_rate}%)` : "")
    : null;
  const measuredAt = `measured at \`${(cov.commit || "?").slice(0, 9)}\`` + (cov.date ? ` (${cov.date.slice(0, 10)})` : "");
  lines.push(`> ${caseLine ? caseLine + " · " : ""}${measuredAt}`);
  if (cov.branch_union.exact === false) {
    lines.push("> branch union is a LOWER BOUND (some entries reported no branch mask)");
  }
  lines.push("");
}

// Fuel readings are only comparable when both snapshots metered on the same
// wasmtime version -- the per-instruction cost table lives in wasmtime.
const execCur = cur.exec;
const execBase = base?.exec;
const wasmtimeChanged = !!(execBase?.scenarios && execCur?.wasmtime && execBase.wasmtime &&
  execCur.wasmtime !== execBase.wasmtime);

// Tracks which metrics a row already shows, so the drift line does not repeat
// them.
const rendered = new Set();
const show = (key) => { rendered.add(key); return true; };

// --- Large: the compiler itself -------------------------------------------------
lines.push("#### Large — the compiler itself");
lines.push("");
lines.push("| subject | memory | code | bench (B/op) |");
lines.push("|---|---:|---:|---:|");
show("selfcompile.heap_ptr_bytes");
show("sizes.stage2_wasm");
show(`benches.${REPRESENTATIVE.largeBench}`);
lines.push(`| selfcompile | ${cell(fmtBytes, cur.selfcompile?.heap_ptr_bytes, base?.selfcompile?.heap_ptr_bytes)} | ` +
  `${cell(fmtBytes, cur.sizes?.stage2_wasm, base?.sizes?.stage2_wasm)} | ` +
  `${cell(fmtBytes, cur.benches?.[REPRESENTATIVE.largeBench]?.bytes_per_op, base?.benches?.[REPRESENTATIVE.largeBench]?.bytes_per_op)} |`);
lines.push("");

// --- Medium: a real program ------------------------------------------------------
const medName = REPRESENTATIVE.medium;
const medCur = execCur?.scenarios?.[medName];
const medBase = execBase?.scenarios?.[medName];
lines.push(`#### Medium — a real program (\`${medName}\`, bench/exec)`);
lines.push("");
lines.push("| scenario | heap | code | fuel |");
lines.push("|---|---:|---:|---:|");
show(`exec.${medName}.linear.heap_bytes`);
show(`exec.${medName}.linear.wasm_bytes`);
if (!wasmtimeChanged) show(`exec.${medName}.linear.fuel`);
lines.push(`| ${medName} | ${cell(fmtBytes, medCur?.linear?.heap_bytes, medBase?.linear?.heap_bytes)} | ` +
  `${cell(fmtBytes, medCur?.linear?.wasm_bytes, medBase?.linear?.wasm_bytes)} | ` +
  `${cell(fmtCount, medCur?.linear?.fuel, medBase?.linear?.fuel, !wasmtimeChanged)} |`);
lines.push("");

// --- Small: micro ---------------------------------------------------------------
lines.push("#### Small — micro");
lines.push("");
lines.push("| case | code | B/op |");
lines.push("|---|---:|---:|");
show(`sizes.samples.${REPRESENTATIVE.smallSample}`);
show(`benches.${REPRESENTATIVE.smallBench}`);
lines.push(`| ${REPRESENTATIVE.smallSample} | ${cell(fmtBytes, cur.sizes?.samples?.[REPRESENTATIVE.smallSample], base?.sizes?.samples?.[REPRESENTATIVE.smallSample])} | ` +
  `${cell(fmtBytes, cur.benches?.[REPRESENTATIVE.smallBench]?.bytes_per_op, base?.benches?.[REPRESENTATIVE.smallBench]?.bytes_per_op)} |`);
lines.push("");

// A representative with no VALUE renders "– (–)", which reads like "no change"
// at a glance. Say it instead: the row's heading promises a number, so a blank
// one means the report is measuring less than it claims.
//
// Checked per CELL, not per object. A scenario can be present and `ok` while
// the metric inside it is null -- `bench_metrics.sh` scrapes fuel and memory
// out of the runner's stderr, so a runner that ran fine but printed no
// `vibe::fuel` line stores null under an `ok` status (#2643 review, Codex P2).
const missingReps = [];
const repCell = (label, v) => { if (v == null) missingReps.push(label); };
repCell("selfcompile heap", cur.selfcompile?.heap_ptr_bytes);
repCell("stage2.wasm", cur.sizes?.stage2_wasm);
repCell(`B/op ${REPRESENTATIVE.largeBench}`, cur.benches?.[REPRESENTATIVE.largeBench]?.bytes_per_op);
if (execCur?.scenarios) {
  repCell(`${medName} heap`, medCur?.linear?.heap_bytes);
  repCell(`${medName} wasm`, medCur?.linear?.wasm_bytes);
  if (!wasmtimeChanged) repCell(`${medName} fuel`, medCur?.linear?.fuel);
}
repCell(`sample ${REPRESENTATIVE.smallSample}`, cur.sizes?.samples?.[REPRESENTATIVE.smallSample]);
repCell(`B/op ${REPRESENTATIVE.smallBench}`, cur.benches?.[REPRESENTATIVE.smallBench]?.bytes_per_op);
if (missingReps.length) {
  lines.push(`> ⚠️ no value in this snapshot for: ${missingReps.join(" · ")} — the cell above is blank, not flat`);
  lines.push("");
}

// --- drift outside the rendered rows ----------------------------------------
// Every tracked metric, rendered or not, re-checked against the ±2% threshold.
// This is what makes one-row-per-tier safe: the report stays small when
// everything is flat, and a regression in a series nobody chose to render
// still arrives by name.
// Keys from BOTH snapshots, current first, baseline's extras after. Iterating
// `cur` alone means a series the current run did not produce at all is never
// visited: `bench_metrics.sh` records nothing for a binary-size sample that
// failed to compile or a tracked bench that parsed no row, so the series simply
// vanishes rather than going null, and a scan over `cur` would then report the
// rest as clean. Same class as the null-value case below, one level up -- an
// absent KEY instead of an absent VALUE (#2643 review, Codex P2).
const unionKeys = (a, b) => {
  const out = Object.keys(a || {});
  for (const k of Object.keys(b || {})) if (!(k in (a || {}))) out.push(k);
  return out;
};

function* allMetrics() {
  yield ["selfcompile heap", "selfcompile.heap_ptr_bytes", cur.selfcompile?.heap_ptr_bytes, base?.selfcompile?.heap_ptr_bytes];
  for (const k of ["stage2_wasm", "cli_adapter_bundle", "compiler_sources_bundle", "module_source"]) {
    yield [k, `sizes.${k}`, cur.sizes?.[k], base?.sizes?.[k]];
  }
  for (const name of unionKeys(cur.sizes?.samples, base?.sizes?.samples)) {
    yield [`sample ${name}`, `sizes.samples.${name}`, cur.sizes?.samples?.[name], base?.sizes?.samples?.[name]];
  }
  for (const label of unionKeys(cur.benches, base?.benches)) {
    yield [`B/op ${label}`, `benches.${label}`, cur.benches?.[label]?.bytes_per_op, base?.benches?.[label]?.bytes_per_op];
  }
  for (const name of unionKeys(execCur?.scenarios, execBase?.scenarios)) {
    const s = execCur?.scenarios?.[name] || {};
    const b = execBase?.scenarios?.[name];
    if (!wasmtimeChanged) {
      yield [`${name} fuel`, `exec.${name}.linear.fuel`, s.linear?.fuel, b?.linear?.fuel];
      yield [`${name} fuel (gc)`, `exec.${name}.gc.fuel`, s.gc?.fuel, b?.gc?.fuel];
    }
    yield [`${name} heap`, `exec.${name}.linear.heap_bytes`, s.linear?.heap_bytes, b?.linear?.heap_bytes];
    yield [`${name} committed`, `exec.${name}.linear.committed_bytes`, s.linear?.committed_bytes, b?.linear?.committed_bytes];
    yield [`${name} wasm`, `exec.${name}.linear.wasm_bytes`, s.linear?.wasm_bytes, b?.linear?.wasm_bytes];
    yield [`${name} wasm (gc)`, `exec.${name}.gc.wasm_bytes`, s.gc?.wasm_bytes, b?.gc?.wasm_bytes];
  }
}
const drifted = [];
const unmeasured = [];
let compared = 0;
for (const [label, key, c, b] of allMetrics()) {
  if (rendered.has(key)) continue;
  // The baseline had a number and this run does not. That is lost
  // instrumentation, not agreement -- `pctOf` returns null for it, and
  // counting that as a clean scan is exactly how "nothing moved" and "nothing
  // was checked" come to look alike (#2643 review, Codex P2).
  if (c == null && b != null) { unmeasured.push(label); continue; }
  const pct = pctOf(c, b);
  if (pct == null) continue;
  compared += 1;
  if (Math.abs(pct) >= 2) drifted.push(`${label} ${fmtPct(pct)}`);
}
if (drifted.length) {
  lines.push(`> drift outside the rows above (±2% threshold, ${drifted.length}): ${drifted.join(" · ")}`);
  lines.push("");
} else if (compared) {
  lines.push(`> no drift ≥±2% in the ${compared} other tracked series compared`);
  lines.push("");
} else if (base) {
  // Zero comparable series is its own answer, and dropping the line here would
  // reintroduce the ambiguity this scan exists to remove: a reader cannot tell
  // an absent line from a clean one.
  lines.push("> no other tracked series to compare");
  lines.push("");
}
if (unmeasured.length) {
  lines.push(`> ⚠️ measured on the baseline, absent here (${unmeasured.length}): ${unmeasured.join(" · ")} — instrumentation gap, not agreement`);
  lines.push("");
}

// --- correctness -------------------------------------------------------------
// Not a perf number, and the loudest thing here by design: golden (linear vs
// committed expected output) and backend parity (gc vs linear stdout). A
// mismatch is a silent-wrong candidate, so it survives every cut above.
if (execCur?.scenarios && Object.keys(execCur.scenarios).length) {
  if (wasmtimeChanged) {
    lines.push(`> fuel not comparable to baseline: wasmtime ${execBase.wasmtime} → ${execCur.wasmtime} (per-instruction cost table changed) — fuel Δ omitted`);
  }
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
lines.push(`<sub>one representative per tier; every other tracked series is re-checked for ±2% drift above · wall times & runner calibration: recorded in the \`bench-data\` snapshots, not rendered (runner-speed noise — see bench/perf/README.md) · tracked series: bench/perf/tracked_benches.txt · docs: bench/perf/README.md</sub>`);

console.log(lines.join("\n"));
