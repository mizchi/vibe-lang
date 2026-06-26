#!/usr/bin/env node
// Unit tests for the workspace symbol / call-graph index (js/vibe/symbol_index.js).
// Pure JS, no compiler/runner required — runs anywhere node does.
"use strict";
const path = require("path");
const { SymbolIndex, extractFile, codeMask, hashText, fuzzyScore, KIND } =
  require(path.join(__dirname, "..", "js", "vibe", "symbol_index.js"));

let pass = 0, fail = 0;
function ok(cond, name, detail) {
  if (cond) { pass++; console.log(`ok: ${name}`); }
  else { fail++; console.error(`FAIL: ${name}${detail ? " — " + detail : ""}`); }
}
function eq(a, b, name) { ok(JSON.stringify(a) === JSON.stringify(b), name, `${JSON.stringify(a)} !== ${JSON.stringify(b)}`); }

// --- codeMask: comments and strings are blanked, offsets preserved ----------
{
  const src = 'let x = "he(llo" // call me( here\nlet y = 1\n';
  const mask = codeMask(src);
  ok(mask.length === src.length, "codeMask preserves length");
  ok(!/call/.test(mask), "codeMask blanks line comments");
  ok(!mask.includes("he(llo"), "codeMask blanks string contents");
  ok(mask.includes("let y = 1"), "codeMask keeps code");
}

// --- extractFile: top-level symbols only, kinds, body spans -----------------
{
  const src = [
    "export let twice = (x: Int) -> Int { x * 2 }",
    "let combo = (x: Int) -> Int {",
    "  let local = twice(x)        // local must NOT be a symbol",
    "  combo(local)                // self-recursion",
    "}",
    "struct Point { x: Int, y: Int }",
    "enum Color { Red, Green }",
    "let value = 42",
  ].join("\n");
  const ex = extractFile(src);
  const names = ex.symbols.map((s) => s.name).sort();
  eq(names, ["Color", "Point", "combo", "twice", "value"], "extractFile keeps only top-level decls (locals excluded)");
  const byName = Object.fromEntries(ex.symbols.map((s) => [s.name, s]));
  ok(byName.twice.kind === KIND.Function, "let-lambda is Function kind");
  ok(byName.value.kind === KIND.Variable, "let-value is Variable kind");
  ok(byName.Point.kind === KIND.Struct, "struct is Struct kind");
  ok(byName.Color.kind === KIND.Enum, "enum is Enum kind");
  // call attribution
  const callsFromCombo = ex.calls.filter((c) => c.caller === "combo").map((c) => c.callee).sort();
  ok(callsFromCombo.includes("twice") && callsFromCombo.includes("combo"), "calls inside combo attributed to combo", JSON.stringify(callsFromCombo));
  ok(!ex.calls.some((c) => c.caller === null && c.callee === "twice"), "no spurious top-level call of twice");
}

// --- module-nested symbols --------------------------------------------------
{
  const src = "module M {\n  let inner = (x: Int) -> Int { x }\n}\nlet outer = () -> Int { 0 }\n";
  const ex = extractFile(src);
  const inner = ex.symbols.find((s) => s.name === "inner");
  ok(inner && inner.container === "M", "module-nested symbol records its container");
  ok(ex.symbols.some((s) => s.name === "outer" && s.container === null), "top-level symbol after a module still captured");
}

// --- keywords are not calls -------------------------------------------------
{
  const ex = extractFile("let f = (x: Int) -> Int {\n  if (x) { g(x) } else { 0 }\n}\nlet g = (x: Int) -> Int { x }\n");
  ok(!ex.calls.some((c) => c.callee === "if"), "`if (` is not a call");
  ok(ex.calls.some((c) => c.callee === "g"), "real call g() captured");
}

// --- incremental update: hash skip ------------------------------------------
{
  const idx = new SymbolIndex();
  const a = "let f = () -> Int { g() }\nlet g = () -> Int { 0 }\n";
  ok(idx.update("/a.vibe", a) === true, "first update extracts");
  ok(idx.update("/a.vibe", a) === false, "identical re-update is a hash skip");
  ok(idx.update("/a.vibe", a + "let h = () -> Int { 1 }\n") === true, "changed content re-extracts");
  ok(idx.stats().skips === 1, "exactly one hash skip recorded");
}

// --- workspace symbols, definitions, call hierarchy across files ------------
{
  const idx = new SymbolIndex();
  idx.update("/util.vibe", "let twice = (x: Int) -> Int { x * 2 }\nlet inc = (x: Int) -> Int { x + 1 }\nlet combo = (x: Int) -> Int { twice(inc(x)) }\n");
  idx.update("/main.vibe", "let run = () -> Int {\n  let a = combo(10)\n  twice(a)\n}\n");

  const all = idx.workspaceSymbols("");
  eq(all.map((s) => s.name).sort(), ["combo", "inc", "run", "twice"], "workspaceSymbols('') returns all 4");

  const tw = idx.workspaceSymbols("twice");
  ok(tw[0] && tw[0].name === "twice" && tw[0].path === "/util.vibe", "fuzzy query ranks exact name first with its path");

  // incoming calls to twice: combo (util) and run (main) — cross file
  eq(idx.incomingCalls("twice").map((c) => c.caller).sort(), ["combo", "run"], "incomingCalls(twice) spans files");
  // outgoing from combo: inc, twice
  eq(idx.outgoingCalls("combo").map((c) => c.callee).sort(), ["inc", "twice"], "outgoingCalls(combo)");
  ok(idx.outgoingCalls("combo").every((c) => c.defined), "outgoing callees resolve to workspace symbols");

  // remove a file drops its symbols and edges
  idx.remove("/main.vibe");
  eq(idx.incomingCalls("twice").map((c) => c.caller).sort(), ["combo"], "remove() drops a file's call edges");
}

// --- graph export -----------------------------------------------------------
{
  const idx = new SymbolIndex();
  idx.update("/proj/a.vibe", "let f = () -> Int { g() }\nlet g = () -> Int { 0 }\n");
  const g = idx.graph({ root: "/proj" });
  ok(g.nodes.length === 2, "graph has a node per symbol");
  ok(g.nodes.every((n) => n.file === "a.vibe"), "graph node files are root-relative");
  const e = g.edges.find((x) => x.from.endsWith("#f") && x.to.endsWith("#g"));
  ok(e && e.weight === 1, "graph edge f->g with weight", JSON.stringify(g.edges));
}

// --- fuzzy score ordering ---------------------------------------------------
{
  ok(fuzzyScore("check_program", "checkp") >= 0, "subsequence matches");
  ok(fuzzyScore("xyz", "checkp") < 0, "non-subsequence rejected");
  ok(fuzzyScore("check", "check") < fuzzyScore("recheck", "check"), "prefix beats mid-word");
}

// --- hashText is stable & sensitive -----------------------------------------
ok(hashText("abc") === hashText("abc"), "hashText stable");
ok(hashText("abc") !== hashText("abd"), "hashText sensitive");

console.log(`\n[test_symbol_index] ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
