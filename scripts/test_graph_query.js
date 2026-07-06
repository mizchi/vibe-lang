#!/usr/bin/env node
// Unit tests for the project graph query layer (clients/js/graph_query.js).
// Pure JS; builds a synthetic 2-module workspace with a deliberate import cycle.
"use strict";
const path = require("path");
const { SymbolIndex } = require(path.join(__dirname, "..", "js", "vibe", "symbol_index.js"));
const { GraphQuery } = require(path.join(__dirname, "..", "js", "vibe", "graph_query.js"));

let pass = 0, fail = 0;
const ok = (n, c, d) => { c ? (pass++, console.log(`ok: ${n}`)) : (fail++, console.error(`FAIL: ${n}${d ? " — " + d : ""}`)); };
const eq = (a, b, n) => ok(JSON.stringify(a) === JSON.stringify(b), n, `${JSON.stringify(a)} !== ${JSON.stringify(b)}`);

const ROOT = "/proj";
const idx = new SymbolIndex();
// app/main -> app/util, core (dir => core/index), prelude/result (EXTERNAL, unresolved)
idx.update("/proj/app/main.vibe", "import ./util.vibe { u }\nimport ../core { c }\nimport ../prelude/result.vibe { Result }\nlet main = () -> Int { u() }\n");
idx.update("/proj/app/util.vibe", "import ../core/helpers.vibe { h }\nlet u = () -> Int { h() }\n");
idx.update("/proj/core/index.vibe", "import ./helpers.vibe { h }\nlet c = () -> Int { h() }\n");
// core/helpers imports back into app => a module-level cycle app <-> core
idx.update("/proj/core/helpers.vibe", "import ../app/util.vibe { u }\nlet h = () -> Int { 0 }\n");
const q = new GraphQuery(idx, { root: ROOT });

// --- import resolution (directory => /index.vibe, file as-is, external => null)
ok("dir import resolves to <dir>/index.vibe", q.resolveImport("/proj/app/main.vibe", "../core") === "/proj/core/index.vibe");
ok("file import resolves as-is", q.resolveImport("/proj/app/util.vibe", "../core/helpers.vibe") === "/proj/core/helpers.vibe");
ok("unresolved external import => null", q.resolveImport("/proj/app/main.vibe", "../prelude/result.vibe") === null);

// --- stats
const s = q.stats();
eq(s.files, 4, "stats.files");
eq(s.modules, 2, "stats.modules (app, core)");
eq(s.externalImports, 1, "stats.externalImports (prelude/result)");
eq(s.moduleCycles, 1, "stats.moduleCycles");

// --- file-level dependency graph
const fg = q.dependencyGraph("file");
const fe = new Set(fg.edges.map((e) => `${e.from}->${e.to}`));
ok("file edge app/main -> app/util", fe.has("app/main.vibe->app/util.vibe"));
ok("file edge app/main -> core/index (dir import)", fe.has("app/main.vibe->core/index.vibe"));
ok("file edge core/helpers -> app/util (back edge)", fe.has("core/helpers.vibe->app/util.vibe"));
ok("no edge for unresolved external", ![...fe].some((k) => /prelude/.test(k)));
ok("import edge carries imported names", fg.edges.find((e) => e.from === "app/main.vibe" && e.to === "app/util.vibe").names.includes("u"));

// --- module-level dependency graph + queries
const mg = q.dependencyGraph("module");
const me = new Set(mg.edges.map((e) => `${e.from}->${e.to}`));
ok("module edge app -> core", me.has("app->core"));
ok("module edge core -> app", me.has("core->app"));

eq(q.dependents("core", { level: "module" }).nodes.map((n) => n.id).sort(), ["app", "core"], "dependents(core) direct = {app, core(self via traversal seed)}");
ok("dependencies(app) direct includes core", q.dependencies("app", { level: "module" }).nodes.some((n) => n.id === "core"));

// --- cycles
const cyc = q.cycles("module");
eq(cyc.length, 1, "one module cycle");
eq([...cyc[0]].sort(), ["app", "core"], "cycle members = {app, core}");

// --- hotspots (fan-in): both modules depended on once
const hs = q.hotspots({ level: "module", by: "fan-in" });
ok("hotspots rank by fan-in", hs.length === 2 && hs.every((h) => h.score >= 1), JSON.stringify(hs));

// --- path
eq(q.path("app", "core", { level: "module" }), ["app", "core"], "path app -> core");
ok("path to nonexistent node is null", q.path("app", "nope", { level: "module" }) === null);

// --- neighborhood (both directions, depth 1)
const nb = q.neighborhood("core", { level: "module", depth: 1 });
ok("neighborhood(core) includes app (in and out)", nb.nodes.some((n) => n.id === "app"));

// --- symbol-level call queries via the same API
const callees = q.callees("main");
ok("callees(main) includes u (call graph)", callees.nodes.some((n) => n.id === "u"), JSON.stringify(callees.nodes));
const callers = q.callers("h", { transitive: true });
ok("transitive callers(h) reach main", callers.nodes.some((n) => n.id === "main"), JSON.stringify(callers.nodes.map((n) => n.id)));

console.log(`\n[test_graph_query] ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
