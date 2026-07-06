#!/usr/bin/env node
// Project graph CLI: get the dependency graph — or any focused perspective — of
// a vibe workspace in one shot. Builds the in-process symbol index
// (clients/js/symbol_index.js) + graph query layer (clients/js/graph_query.js) and
// emits JSON suitable for macro-level visualization (à la mizchi/sprawlens).
//
// Every query returns a uniform { nodes, edges, ... } subgraph so one renderer
// handles them all.
//
// Usage:
//   node scripts/vibe_graph.js [root] [query] [options]
//
// Queries (default: the full module dependency graph):
//   --deps          <node>     what <node> depends on        (+ --transitive)
//   --dependents    <node>     what depends on <node>        (+ --transitive)
//   --neighborhood  <node>     local subgraph around <node>  (+ --depth N)
//   --path          <a> <b>    shortest dependency path a -> b
//   --cycles                   dependency cycles (SCCs)
//   --hotspots                 most-depended-on nodes        (+ --by fan-out)
//   --stats                    summary stats only
//   --call                     use the call graph (symbol level) instead of imports
//
// Options:
//   --level file|module|symbol (default: module; symbol when --call)
//   --transitive               full closure for --deps/--dependents
//   --depth N                  hops for --neighborhood (default 1)
//   --by fan-in|fan-out        ranking for --hotspots (default fan-in)
//   --functions-only           call graph: keep only function nodes
//   --out FILE                 write JSON to FILE (else stdout)
"use strict";
const fs = require("fs");
const path = require("path");
const { SymbolIndex, KIND } = require(path.join(__dirname, "..", "js", "vibe", "symbol_index.js"));
const { GraphQuery } = require(path.join(__dirname, "..", "js", "vibe", "graph_query.js"));

function parseArgs(argv) {
  const o = { root: null, query: null, args: [], level: null, transitive: false, depth: 1, by: "fan-in", functionsOnly: false, out: null, call: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--deps": case "--dependents": case "--neighborhood": case "--cycles":
      case "--hotspots": case "--stats": case "--path":
        o.query = a.slice(2);
        break;
      case "--transitive": o.transitive = true; break;
      case "--call": o.call = true; break;
      case "--functions-only": o.functionsOnly = true; break;
      case "--level": o.level = argv[++i]; break;
      case "--depth": o.depth = +argv[++i]; break;
      case "--by": o.by = argv[++i]; break;
      case "--out": o.out = argv[++i]; break;
      default:
        if (a.startsWith("--")) break;
        if (!o.root && (o.query === null && o.args.length === 0)) o.root = a;
        else o.args.push(a);
    }
  }
  // First positional may be the root OR a query arg; disambiguate: if it's an
  // existing dir, it's the root.
  if (o.root && o.query && o.args.length === 0 && !fs.existsSync(o.root)) { o.args.unshift(o.root); o.root = null; }
  return o;
}

function walk(dir, acc) {
  let ents; try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!["node_modules", ".git", "target"].includes(e.name)) walk(p, acc); }
    else if (p.endsWith(".vibe")) acc.push(p);
  }
  return acc;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const root = path.resolve(o.root || process.cwd());
  const t0 = Number(process.hrtime.bigint()) / 1e6;
  const idx = new SymbolIndex();
  for (const f of walk(root, [])) { try { idx.update(f, fs.readFileSync(f, "utf8")); } catch {} }
  const q = new GraphQuery(idx, { root });
  const level = o.level || (o.call ? "symbol" : "module");

  let result;
  switch (o.query) {
    case "stats": result = q.stats(); break;
    case "deps": result = q.dependencies(o.args[0], { level, transitive: o.transitive }); break;
    case "dependents": result = q.dependents(o.args[0], { level, transitive: o.transitive }); break;
    case "neighborhood": result = q.neighborhood(o.args[0], { level, depth: o.depth }); break;
    case "path": result = { view: "path", from: o.args[0], to: o.args[1], path: q.path(o.args[0], o.args[1], { level }) }; break;
    case "cycles": result = { view: "cycles", level, cycles: q.cycles(level) }; break;
    case "hotspots": result = { view: "hotspots", level, by: o.by, hotspots: q.hotspots({ level, by: o.by }) }; break;
    default: {
      // Full graph. Call graph (symbol) or dependency graph (file/module).
      if (o.call || level === "symbol") {
        let g = q.callGraph();
        if (o.functionsOnly) {
          const fnIds = new Set(g.nodes.filter((n) => n.kind === KIND.Function).map((n) => n.id));
          g.nodes = g.nodes.filter((n) => fnIds.has(n.id));
          g.edges = g.edges.filter((e) => fnIds.has(e.from) && fnIds.has(e.to));
        }
        result = Object.assign({ view: "call-graph", level: "symbol" }, g);
      } else {
        result = Object.assign({ view: "dependency-graph" }, q.dependencyGraph(level));
      }
    }
  }
  // Attach project stats to every result except the stats query itself (which
  // already IS the stats object).
  if (o.query !== "stats") result.stats = Object.assign({ ms: +(Number(process.hrtime.bigint()) / 1e6 - t0).toFixed(1) }, q.stats());
  else result.ms = +(Number(process.hrtime.bigint()) / 1e6 - t0).toFixed(1);

  const json = JSON.stringify(result, null, o.out ? 0 : 2);
  if (o.out) {
    fs.writeFileSync(o.out, json);
    // The --stats result IS the stats object (files/ms at top level); every other
    // result carries them under result.stats. Read from whichever applies.
    const st = o.query === "stats" ? result : result.stats;
    const counts = result.nodes ? `${result.nodes.length} nodes, ${result.edges.length} edges` : (result.cycles ? `${result.cycles.length} cycles` : "ok");
    process.stderr.write(`vibe graph (${result.view || o.query}) -> ${o.out}: ${counts}, ${st.files} files in ${st.ms} ms\n`);
  } else {
    process.stdout.write(json + "\n");
  }
}

main();
