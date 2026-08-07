#!/usr/bin/env node
// Render the span tree scripts/trace_span.sh writes.
//
//   VIBE_TRACE_OUT=/tmp/build.ndjson pkf run test
//   node scripts/trace_report.mjs /tmp/build.ndjson [--top N]
//
// Prints, per trace: the tree with wall time and self time, then the critical
// path. Self time is a span's own wall minus the wall of its children that do
// not overlap each other -- with parallel fan-out the children's walls sum to
// more than the parent's, so summing them would report negative self time.
//
// docs/tracing-design.md step 0. This reads only what the host emits (one span
// per process); guest-side phase spans are a later step.
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const path = args.find((a) => !a.startsWith("--"));
const topIdx = args.indexOf("--top");
const TOP = topIdx >= 0 ? Number(args[topIdx + 1]) : 0;
if (!path) {
  console.error("usage: trace_report.mjs <trace.ndjson> [--top N]");
  process.exit(2);
}

const spans = [];
for (const line of readFileSync(path, "utf8").split("\n")) {
  if (!line.trim()) continue;
  try {
    spans.push(JSON.parse(line));
  } catch {
    // A torn line means two writers raced past the atomic-append size. Count
    // it rather than dying: a partly-readable trace still answers "what was
    // slow", and silently dropping it would misreport the tree as complete.
    spans.push(null);
  }
}
const torn = spans.filter((s) => s === null).length;
const ok = spans.filter(Boolean);
if (torn) console.log(`note: ${torn} unparseable line(s) skipped\n`);
if (!ok.length) {
  console.log("no spans");
  process.exit(0);
}

const ms = (ns) => (ns / 1e6).toFixed(1).padStart(9);

// Union of child intervals, so overlapping (parallel) children are counted once.
function unionNs(intervals) {
  if (!intervals.length) return 0;
  const s = [...intervals].sort((a, b) => a[0] - b[0]);
  let total = 0, [cs, ce] = s[0];
  for (const [a, b] of s.slice(1)) {
    if (a > ce) { total += ce - cs; cs = a; ce = b; } else if (b > ce) ce = b;
  }
  return total + (ce - cs);
}

for (const tid of [...new Set(ok.map((s) => s.tid))]) {
  const rows = ok.filter((s) => s.tid === tid);
  const byId = new Map(rows.map((s) => [s.sid, s]));
  const kids = new Map(rows.map((s) => [s.sid, []]));
  const roots = [];
  for (const s of rows) {
    if (s.pid && kids.has(s.pid)) kids.get(s.pid).push(s);
    else roots.push(s);
  }
  for (const list of kids.values()) list.sort((a, b) => a.t0 - b.t0);
  roots.sort((a, b) => a.t0 - b.t0);

  const self = (s) => (s.t1 - s.t0) - unionNs(kids.get(s.sid).map((c) => [c.t0, c.t1]));

  console.log(`trace ${tid}  (${rows.length} spans)`);
  console.log("     wall       self  name");
  const walk = (s, depth) => {
    const flag = s.rc === 0 ? "" : `  rc=${s.rc}`;
    console.log(`${ms(s.t1 - s.t0)} ${ms(self(s))}  ${"  ".repeat(depth)}${s.name}${flag}`);
    for (const c of kids.get(s.sid)) walk(c, depth + 1);
  };
  for (const r of roots) walk(r, 0);

  // Critical path: from each root, repeatedly descend into the child whose
  // interval ends last -- the one the parent actually waited on.
  console.log("\ncritical path:");
  for (const r of roots) {
    const chain = [];
    let cur = r;
    while (cur) {
      chain.push(`${cur.name} (${((cur.t1 - cur.t0) / 1e6).toFixed(0)}ms)`);
      const cs = kids.get(cur.sid);
      cur = cs.length ? cs.reduce((a, b) => (b.t1 > a.t1 ? b : a)) : null;
    }
    console.log(`  ${chain.join(" -> ")}`);
  }

  if (TOP > 0) {
    console.log(`\nslowest ${TOP} by self time:`);
    for (const s of [...rows].sort((a, b) => self(b) - self(a)).slice(0, TOP)) {
      console.log(`${ms(self(s))}  ${s.name}`);
    }
  }
  console.log("");
}
