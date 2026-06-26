#!/usr/bin/env node
// Project graph query layer over the workspace symbol index (symbol_index.js).
//
// The index gives per-file symbols, imports, and call edges. This layer resolves
// those into a queryable PROJECT GRAPH at three levels:
//
//   - symbol : call graph (symbol -> symbol)
//   - file   : import dependency graph (file -> file), resolved like the compiler
//   - module : the file graph collapsed by directory (each dir is a module)
//
// and answers macro-level questions in one shot — the whole dependency graph, or
// a focused perspective (what depends on X, what X reaches, cycles, hotspots, a
// path between two nodes, the neighborhood around a node). Every query returns a
// uniform { nodes, edges } subgraph (plus analysis-specific extras), so a single
// renderer / consumer handles them all.
//
// Import resolution mirrors the selfhost loader's resolve_import_path_candidates:
// a spec ending in `.vibe` is taken as-is; otherwise `<p>.vibe` then
// `<p>/index.vibe` are tried (directory module). Unresolved specs (prelude /
// stdlib / external) are recorded but produce no internal edge.
"use strict";
const path = require("path");
const { KIND } = require("./symbol_index.js");

class GraphQuery {
  // index: a SymbolIndex; root: absolute workspace root for relativizing ids.
  constructor(index, opts = {}) {
    this.index = index;
    this.root = opts.root ? path.resolve(opts.root) : "";
    this._build();
  }

  rel(p) {
    if (!this.root) return p;
    const r = path.relative(this.root, p);
    return r.startsWith("..") ? p : r;
  }
  moduleOf(p) {
    const r = this.rel(p);
    const d = path.dirname(r);
    return d === "." ? "(root)" : d;
  }

  // Resolve an import spec from a file to an indexed file path, or null.
  resolveImport(fromPath, rawPath) {
    const dir = path.dirname(fromPath);
    const joined = path.resolve(dir, rawPath);
    const candidates = rawPath.endsWith(".vibe")
      ? [joined]
      : [joined + ".vibe", path.join(joined, "index.vibe")];
    for (const c of candidates) if (this.index.files.has(c)) return c;
    return null;
  }

  _build() {
    const files = this.index.files;
    // file-level import edges + unresolved specs
    this.fileEdges = new Map(); // fromRel -> Map(toRel -> {names:Set})
    this.fileExternals = new Map(); // fromRel -> [rawPath,...] unresolved
    this.fileSet = new Set();
    for (const [p] of files) this.fileSet.add(this.rel(p));
    for (const [p, f] of files) {
      const fromRel = this.rel(p);
      const tgt = this.fileEdges.get(fromRel) || new Map();
      for (const imp of f.imports) {
        const resolved = this.resolveImport(p, imp.path);
        if (resolved && resolved !== p) {
          const toRel = this.rel(resolved);
          const e = tgt.get(toRel) || { names: new Set() };
          for (const n of imp.names) e.names.add(n);
          tgt.set(toRel, e);
        } else if (!resolved) {
          const ex = this.fileExternals.get(fromRel) || [];
          ex.push(imp.path);
          this.fileExternals.set(fromRel, ex);
        }
      }
      if (tgt.size) this.fileEdges.set(fromRel, tgt);
    }
    // module-level edges (collapse file edges by directory)
    this.moduleEdges = new Map(); // fromMod -> Map(toMod -> weight)
    this.moduleSet = new Set();
    for (const [p] of files) this.moduleSet.add(this.moduleOf(p));
    for (const [fromRel, tgt] of this.fileEdges) {
      const fromMod = this.moduleOf(path.resolve(this.root || "", fromRel));
      const mt = this.moduleEdges.get(fromMod) || new Map();
      for (const [toRel] of tgt) {
        const toMod = this.moduleOf(path.resolve(this.root || "", toRel));
        if (toMod === fromMod) continue;
        mt.set(toMod, (mt.get(toMod) || 0) + 1);
      }
      if (mt.size) this.moduleEdges.set(fromMod, mt);
    }
  }

  // ---- adjacency accessors per level/direction --------------------------
  // Returns a function nodeId -> [{ to, weight }] for the requested edges.
  _adj(level, direction) {
    if (level === "symbol") {
      const fwd = (id) => this.index.outgoingCalls(id).filter((c) => c.defined).map((c) => ({ to: c.callee, weight: c.count }));
      const rev = (id) => this.index.incomingCalls(id).map((c) => ({ to: c.caller, weight: c.count }));
      return direction === "in" ? rev : fwd;
    }
    if (level === "file") {
      const fwd = (id) => [...((this.fileEdges.get(id) || new Map()).keys())].map((to) => ({ to, weight: 1 }));
      const rev = (id) => { const out = []; for (const [from, t] of this.fileEdges) if (t.has(id)) out.push({ to: from, weight: 1 }); return out; };
      return direction === "in" ? rev : fwd;
    }
    // module
    const fwd = (id) => [...((this.moduleEdges.get(id) || new Map()).entries())].map(([to, weight]) => ({ to, weight }));
    const rev = (id) => { const out = []; for (const [from, t] of this.moduleEdges) if (t.has(id)) out.push({ to: from, weight: t.get(id) }); return out; };
    return direction === "in" ? rev : fwd;
  }

  _allNodes(level) {
    if (level === "symbol") return new Set(this.index.workspaceSymbols("", 1e9).filter((s) => s.kind === KIND.Function).map((s) => s.name));
    if (level === "file") return new Set(this.fileSet);
    return new Set(this.moduleSet);
  }

  // ---- one-shot whole graphs --------------------------------------------
  // The full import dependency graph at file or module level.
  dependencyGraph(level = "module") {
    const nodes = [...this._allNodes(level)].map((id) => ({ id, level }));
    const edges = [];
    if (level === "file") {
      for (const [from, t] of this.fileEdges) for (const [to, e] of t) edges.push({ from, to, weight: 1, names: [...e.names] });
    } else {
      for (const [from, t] of this.moduleEdges) for (const [to, w] of t) edges.push({ from, to, weight: w });
    }
    return { level, edge: "import", nodes, edges };
  }

  // The full call graph at symbol level (edges to workspace-defined functions).
  callGraph() { return this.index.graph({ root: this.root }); }

  // ---- perspectives (uniform subgraph results) --------------------------
  // BFS reachable set from `start` along `direction` up to `depth`, with edges.
  _traverse(level, start, { depth = Infinity, direction = "out" } = {}) {
    const adj = this._adj(level, direction);
    const seen = new Set([start]);
    const edges = [];
    let frontier = [start];
    let d = 0;
    while (frontier.length && d < depth) {
      const next = [];
      for (const n of frontier) {
        for (const { to, weight } of adj(n)) {
          edges.push(direction === "in" ? { from: to, to: n, weight } : { from: n, to, weight });
          if (!seen.has(to)) { seen.add(to); next.push(to); }
        }
      }
      frontier = next; d++;
    }
    return { nodes: [...seen].map((id) => ({ id, level })), edges, root: start };
  }

  // What `node` depends on (out edges). transitive => full closure.
  dependencies(node, { level = "module", transitive = false } = {}) {
    return Object.assign(this._traverse(level, node, { direction: "out", depth: transitive ? Infinity : 1 }), { view: "dependencies", edge: level === "symbol" ? "call" : "import" });
  }
  // What depends ON `node` (in edges) — the impact set.
  dependents(node, { level = "module", transitive = false } = {}) {
    return Object.assign(this._traverse(level, node, { direction: "in", depth: transitive ? Infinity : 1 }), { view: "dependents", edge: level === "symbol" ? "call" : "import" });
  }
  // Call-graph conveniences (symbol level).
  callees(symbol, { transitive = false } = {}) { return this.dependencies(symbol, { level: "symbol", transitive }); }
  callers(symbol, { transitive = false } = {}) { return this.dependents(symbol, { level: "symbol", transitive }); }

  // The neighborhood around a node: both directions, up to `depth`.
  neighborhood(node, { level = "module", depth = 1 } = {}) {
    const out = this._traverse(level, node, { direction: "out", depth });
    const inc = this._traverse(level, node, { direction: "in", depth });
    const nodes = new Map();
    for (const n of [...out.nodes, ...inc.nodes]) nodes.set(n.id, n);
    return { view: "neighborhood", level, edge: level === "symbol" ? "call" : "import", root: node, nodes: [...nodes.values()], edges: [...out.edges, ...inc.edges] };
  }

  // Shortest path between two nodes along the chosen edges (BFS), or null.
  path(from, to, { level = "module", direction = "out" } = {}) {
    const adj = this._adj(level, direction);
    const prev = new Map([[from, null]]);
    const q = [from];
    while (q.length) {
      const n = q.shift();
      if (n === to) { const p = []; for (let c = to; c != null; c = prev.get(c)) p.unshift(c); return p; }
      for (const { to: m } of adj(n)) if (!prev.has(m)) { prev.set(m, n); q.push(m); }
    }
    return null;
  }

  // Dependency cycles (strongly-connected components of size > 1, plus self-loops)
  // via Tarjan. Returns arrays of node ids, largest first.
  cycles(level = "module") {
    const adj = this._adj(level, "out");
    const nodes = [...this._allNodes(level)];
    let idx = 0;
    const index = new Map(), low = new Map(), onStack = new Set(), stack = [];
    const sccs = [];
    const strongconnect = (v) => {
      index.set(v, idx); low.set(v, idx); idx++;
      stack.push(v); onStack.add(v);
      for (const { to: w } of adj(v)) {
        if (!index.has(w)) { strongconnect(w); low.set(v, Math.min(low.get(v), low.get(w))); }
        else if (onStack.has(w)) low.set(v, Math.min(low.get(v), index.get(w)));
      }
      if (low.get(v) === index.get(v)) {
        const comp = [];
        let w;
        do { w = stack.pop(); onStack.delete(w); comp.push(w); } while (w !== v);
        if (comp.length > 1) sccs.push(comp);
        else if (adj(v).some((e) => e.to === v)) sccs.push(comp); // self-cycle
      }
    };
    for (const v of nodes) if (!index.has(v)) strongconnect(v);
    return sccs.sort((a, b) => b.length - a.length);
  }

  // Hotspots: nodes ranked by fan-in (most depended-on) or fan-out (most
  // dependencies). `by` = "fan-in" | "fan-out".
  hotspots({ level = "module", by = "fan-in", limit = 20 } = {}) {
    const direction = by === "fan-in" ? "in" : "out";
    const adj = this._adj(level, direction);
    const scored = [...this._allNodes(level)].map((id) => ({ id, score: adj(id).reduce((s, e) => s + (e.weight || 1), 0), degree: adj(id).length }));
    return scored.filter((s) => s.degree > 0).sort((a, b) => b.score - a.score || b.degree - a.degree).slice(0, limit);
  }

  // Summary stats over the whole project graph.
  stats() {
    let fileEdgeCount = 0; for (const t of this.fileEdges.values()) fileEdgeCount += t.size;
    let moduleEdgeCount = 0; for (const t of this.moduleEdges.values()) moduleEdgeCount += t.size;
    let external = 0; for (const e of this.fileExternals.values()) external += e.length;
    return {
      files: this.fileSet.size,
      modules: this.moduleSet.size,
      fileImports: fileEdgeCount,
      moduleDeps: moduleEdgeCount,
      externalImports: external,
      moduleCycles: this.cycles("module").length,
    };
  }
}

module.exports = { GraphQuery };
