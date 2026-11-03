#!/usr/bin/env node
// Reserved-page KPI for fixed package closures (#3647, part of #2509).
//
// The selfcompile heap KPI compiles the whole compiler and cannot see whether
// ONE package fits in 128 MiB. This compiles three fixed probes, each a
// package test file whose import closure the loader resolves, and reports
// reserved linear memory:
//
//   pages            memory.buffer.byteLength / 64 KiB at the end of the run,
//                    the number the isolate limit counts. THIS is the KPI.
//   heap_ptr_bytes   the bump arena's high-water. A diagnostic: how much of the
//                    reserved memory the arena reached.
//
// Neither is reachable RC bytes or the host's peak RSS. Live-block and
// fragmentation accounting stays in #2509.
//
// Every trial is one cold compile with an isolated cache (selfcompile_kpi.sh),
// repeated, and the gate reads the LARGEST page count of the trials. A trial
// that reports no page count is an instrumentation failure, never a zero.
//
//   node scripts/reserved_pages_kpi.mjs <stage2.wasm> [--trials N]
//        [--report-only] [--json-out FILE] [--print-baseline]
//
// Exit: 0 every probe within its regression threshold; 1 a probe over its
// threshold, or a missing metric / closure / baseline row; 2 usage.
//
// Overridable for the self-test only:
//   VIBE_PAGES_KPI_BASELINE   baseline file (default bench/perf/reserved_pages_baseline.tsv)
//   VIBE_PAGES_KPI_VIBE       launcher that answers `deps` (default runtime/vibe)
//   VIBE_KPI_RUNNER_SCRIPT    passed through to selfcompile_kpi.sh
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PAGE_BYTES = 65536;
const TAG = "[reserved-pages-kpi]";

function fail(message, code = 1) {
  process.stderr.write(`${TAG} ${message}\n`);
  process.exit(code);
}

export function parseArgs(argv) {
  const opts = { stage2: "", trials: 3, reportOnly: false, jsonOut: "", printBaseline: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--trials") {
      const n = Number(argv[++i]);
      if (!Number.isInteger(n) || n < 1) throw new Error("--trials takes a positive integer");
      opts.trials = n;
    } else if (a === "--report-only") opts.reportOnly = true;
    else if (a === "--print-baseline") opts.printBaseline = true;
    else if (a === "--json-out") {
      opts.jsonOut = argv[++i] ?? "";
      if (!opts.jsonOut) throw new Error("--json-out takes a path");
    } else if (a.startsWith("-")) throw new Error(`unknown option: ${a}`);
    else if (!opts.stage2) opts.stage2 = a;
    else throw new Error(`unexpected argument: ${a}`);
  }
  if (!opts.stage2) throw new Error("usage: reserved_pages_kpi.mjs <stage2.wasm> [--trials N] [--report-only] [--json-out FILE] [--print-baseline]");
  return opts;
}

// Baseline file: comments and blank lines ignored; directives are
//   tolerance_percent <n>
//   target_pages <n>
//   case <probe> <pages> <heap_ptr_bytes>
export function parseBaseline(text) {
  const out = { tolerancePercent: null, targetPages: null, cases: new Map() };
  text.split("\n").forEach((raw, idx) => {
    const line = raw.trim();
    if (!line || line.startsWith("#")) return;
    const f = line.split(/\s+/);
    const where = `baseline line ${idx + 1}`;
    const num = s => {
      if (!/^[0-9]+$/.test(s ?? "")) throw new Error(`${where}: expected a whole number, got ${JSON.stringify(s)}`);
      return Number(s);
    };
    if (f[0] === "tolerance_percent" && f.length === 2) out.tolerancePercent = num(f[1]);
    else if (f[0] === "target_pages" && f.length === 2) out.targetPages = num(f[1]);
    else if (f[0] === "case" && f.length === 4) {
      if (out.cases.has(f[1])) throw new Error(`${where}: duplicate case ${f[1]}`);
      out.cases.set(f[1], { pages: num(f[2]), heapPtrBytes: num(f[3]) });
    } else throw new Error(`${where}: unrecognised directive: ${line}`);
  });
  if (out.tolerancePercent === null) throw new Error("baseline has no tolerance_percent");
  if (out.targetPages === null) throw new Error("baseline has no target_pages");
  if (out.cases.size === 0) throw new Error("baseline has no case rows");
  return out;
}

// One selfcompile_kpi.sh output line -> metrics. A missing or non-numeric
// field is refused here, so `mem_pages=?` can never be read as 0.
export function parseKpiLine(stdout) {
  const line = stdout.split("\n").filter(l => l.startsWith("[selfcompile-kpi] input=")).at(-1);
  if (!line) throw new Error("selfcompile_kpi.sh printed no [selfcompile-kpi] line");
  const field = name => {
    const m = line.match(new RegExp(`(?:^| )${name}=(\\S+)`));
    if (!m || !/^[0-9]+$/.test(m[1])) throw new Error(`instrumentation failure: ${name} missing or not a number in: ${line}`);
    return Number(m[1]);
  };
  return { pages: field("mem_pages"), heapPtrBytes: field("heap_ptr_bytes"), wallMs: field("wall_ms") };
}

export function gatePages(baselinePages, tolerancePercent) {
  return Math.floor((baselinePages * (100 + tolerancePercent)) / 100);
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

function run(cmd, args, env) {
  return spawnSync(cmd, args, { cwd: ROOT, env: { ...process.env, ...env }, encoding: "utf8", maxBuffer: 64 << 20 });
}

// The loader's own closure (`vibe deps`), not a line count. The probe itself
// is the last member; content is hashed so a later reading can tell whether it
// measured the same input.
function closureOf(stage2, probe) {
  const launcher = process.env.VIBE_PAGES_KPI_VIBE || "runtime/vibe";
  const env = { VIBE_CLI_WASM: stage2 };
  const viberun = path.join(ROOT, "runtime/viberun/target/release/viberun");
  // Any runner answers `deps` the same way; a checkout without a built
  // viberun (a CI job that only staged the compiler) uses the node one.
  if (!process.env.VIBE_RUNNER) env.VIBE_RUNNER = existsSync(viberun) ? viberun : path.join(ROOT, "scripts/viberun_node.sh");
  const r = run("bash", [launcher, "deps", probe], env);
  if (r.status !== 0) throw new Error(`vibe deps ${probe} failed (exit ${r.status}): ${(r.stderr || "").trim().split("\n").at(-1) ?? ""}`);
  const members = r.stdout.split("\n").map(s => s.trim()).filter(Boolean);
  members.push(probe);
  const h = createHash("sha256");
  let lines = 0;
  for (const m of members) {
    const abs = path.resolve(ROOT, m);
    if (!existsSync(abs)) throw new Error(`vibe deps named ${m}, which does not exist`);
    const body = readFileSync(abs);
    lines += body.toString("utf8").split("\n").length - (body.at(-1) === 0x0a ? 1 : 0);
    h.update(`${path.relative(ROOT, abs)}\0${body.length}\0`).update(body);
  }
  return { files: members.length, lines, sha256: h.digest("hex") };
}

function trial(stage2, probe) {
  const r = run("bash", ["scripts/selfcompile_kpi.sh", stage2, probe], {});
  if (r.status !== 0) {
    throw new Error(`selfcompile_kpi.sh ${probe} failed (exit ${r.status}): ${(r.stderr || "").trim().split("\n").slice(-3).join(" | ")}`);
  }
  return parseKpiLine(r.stdout);
}

function identity(stage2) {
  const git = args => {
    const r = run("git", args, {});
    return r.status === 0 ? r.stdout.trim() : "";
  };
  const dirty = git(["status", "--porcelain", "--", "lib", "bootstrap/seed.json"]);
  return {
    stage2,
    stage2Sha256: sha256(readFileSync(path.resolve(ROOT, stage2))),
    sourceHead: git(["rev-parse", "HEAD"]) || "unknown",
    sourceDirty: dirty ? "yes" : "no",
    // A generation directory is named for the commit it was built from
    // (generations.sh); an artifact named any other way cannot say.
    sourceMatched: (() => {
      const short = git(["rev-parse", "--short", "HEAD"]);
      if (!short) return "unknown";
      if (stage2.includes(`_${short}/`)) return "yes";
      return /generations\/[^/]+_[0-9a-f]{7,}\//.test(stage2) ? "no" : "unknown";
    })(),
  };
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    fail(e.message, 2);
  }
  if (!existsSync(path.resolve(ROOT, opts.stage2))) fail(`stage2 not found: ${opts.stage2}`, 2);
  const baselinePath = process.env.VIBE_PAGES_KPI_BASELINE || "bench/perf/reserved_pages_baseline.tsv";
  let baseline;
  try {
    baseline = parseBaseline(readFileSync(path.resolve(ROOT, baselinePath), "utf8"));
  } catch (e) {
    fail(`${baselinePath}: ${e.message}`);
  }

  const id = identity(opts.stage2);
  console.log(`${TAG} compiler=${id.stage2} stage2_sha256=${id.stage2Sha256} source_head=${id.sourceHead} source_dirty=${id.sourceDirty} source_matched=${id.sourceMatched} trials=${opts.trials} tolerance_percent=${baseline.tolerancePercent} target_pages=${baseline.targetPages}`);

  const results = [];
  let failed = false;
  for (const [probe, base] of baseline.cases) {
    const row = { probe, baseline: base };
    try {
      if (!existsSync(path.resolve(ROOT, probe))) throw new Error(`probe not found: ${probe}`);
      row.closure = closureOf(opts.stage2, probe);
      row.trials = [];
      for (let i = 0; i < opts.trials; i++) row.trials.push(trial(opts.stage2, probe));
    } catch (e) {
      process.stderr.write(`${TAG} FAIL probe=${probe}: ${e.message}\n`);
      failed = true;
      results.push({ ...row, error: e.message });
      continue;
    }
    const pages = row.trials.map(t => t.pages);
    const heaps = row.trials.map(t => t.heapPtrBytes);
    const max = Math.max(...pages);
    const gate = gatePages(base.pages, baseline.tolerancePercent);
    row.pagesMax = max;
    row.pagesSpread = max - Math.min(...pages);
    row.gatePages = gate;
    row.overTarget = max > baseline.targetPages;
    row.status = max > gate ? "over-threshold" : "ok";
    console.log(
      `${TAG} probe=${probe} closure_files=${row.closure.files} closure_lines=${row.closure.lines} ` +
        `closure_sha256=${row.closure.sha256.slice(0, 16)} pages=${max} pages_spread=${row.pagesSpread} ` +
        `reserved_bytes=${max * PAGE_BYTES} heap_ptr_bytes=${Math.max(...heaps)} wall_ms_median=${median(row.trials.map(t => t.wallMs))} ` +
        `baseline_pages=${base.pages} gate_pages=${gate} target=${row.overTarget ? "over" : "under"} status=${row.status}`,
    );
    if (row.status !== "ok") {
      process.stderr.write(
        `${TAG} GATE FAIL probe=${probe}: ${max} pages > ${gate} (baseline ${base.pages} + ${baseline.tolerancePercent}%). ` +
          `If the growth is intended, re-measure and update ${baselinePath} (procedure in its header).\n`,
      );
      failed = true;
    }
    results.push(row);
  }

  if (opts.printBaseline) {
    for (const r of results) {
      if (r.trials && !r.error) console.log(`case ${r.probe} ${r.pagesMax} ${Math.max(...r.trials.map(t => t.heapPtrBytes))}`);
    }
  }
  if (opts.jsonOut) {
    writeFileSync(opts.jsonOut, JSON.stringify({ identity: id, tolerancePercent: baseline.tolerancePercent, targetPages: baseline.targetPages, results }, null, 2) + "\n");
  }
  if (failed && !opts.reportOnly) process.exit(1);
  if (results.some(r => r.error)) process.exit(1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
