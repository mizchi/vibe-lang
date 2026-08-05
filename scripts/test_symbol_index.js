#!/usr/bin/env node
// Unit tests for the workspace symbol / call-graph index (clients/js/symbol_index.js).
// Pure JS, no compiler/runner required — runs anywhere node does.
"use strict";
const path = require("path");
const { SymbolIndex, extractFile, codeMask, hashText, fuzzyScore, KIND } =
  require(path.join(__dirname, "..", "clients", "js", "symbol_index.js"));

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
    "struct Point { x: Int; y: Int }",
    "enum Color { Red; Green }",
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

// --- `let rec` / `let mut` modifiers: the NAME, not the modifier ------------
{
  const ex = extractFile("export let rec walk = (n: Int) -> Int { walk(n) }\nlet mut counter = 0\nlet rec a = () -> Int { b() }\nlet b = () -> Int { 0 }\n");
  const names = ex.symbols.map((s) => s.name).sort();
  eq(names, ["a", "b", "counter", "walk"], "`let rec`/`let mut` capture the real name, not 'rec'/'mut'");
  ok(!ex.symbols.some((s) => s.name === "rec" || s.name === "mut"), "no fake 'rec'/'mut' symbol");
  ok(ex.symbols.find((s) => s.name === "walk").kind === KIND.Function, "let rec fn is Function kind");
  ok(ex.calls.some((c) => c.caller === "walk" && c.callee === "walk"), "recursive call attributed to the rec fn");
}

// --- effect-annotated signatures: body is the lambda, not `with E` -------
{
  const ex = extractFile(
    "export let run: (String) -> Unit with Process = (cmd) -> {\n  exec(cmd)\n  log(cmd)\n}\nlet exec = (c: String) -> Unit with Process => 0\n");
  const run = ex.symbols.find((s) => s.name === "run");
  ok(run && run.kind === KIND.Function, "effectful let is a Function");
  const runCalls = ex.calls.filter((c) => c.caller === "run").map((c) => c.callee).sort();
  ok(runCalls.includes("exec") && runCalls.includes("log"), "calls in the real lambda body attribute to the fn (not lost to the effect set)", JSON.stringify(runCalls));
  ok(!ex.calls.some((c) => c.caller === null && (c.callee === "exec" || c.callee === "log")), "effectful-fn body calls are not orphaned to caller:null");
}

// --- call sites carry precise offsets ---------------------------------------
{
  const src = "let a = () -> Int { foo(1) }\nlet foo = (x: Int) -> Int { x }\n";
  const ex = extractFile(src);
  const call = ex.calls.find((c) => c.callee === "foo" && c.caller === "a");
  ok(call && typeof call.off === "number" && call.end === call.off + 3, "call records off..end spanning the callee token");
  ok(src.slice(call.off, call.end) === "foo", "call off..end slices to the callee name", src.slice(call.off, call.end));
}

// --- dependency forms: import {}, export {} re-export, @alias --------------
{
  const ex = extractFile("import ./a.vibe { x }\nexport ./b.vibe { y }\nimport ../json @json\nexport let keep = () -> Int { 0 }\n");
  const paths = ex.imports.map((i) => i.path).sort();
  eq(paths, ["../json", "./a.vibe", "./b.vibe"], "captures import {}, export-{} re-export, and @alias deps");
  ok(ex.imports.find((i) => i.path === "./a.vibe").names.includes("x"), "named import carries names");
  ok(ex.imports.find((i) => i.path === "../json").names.length === 0, "alias import has no names");
  ok(!ex.imports.some((i) => i.path === "keep"), "`export let` decl is NOT a dependency");
  ok(ex.symbols.some((s) => s.name === "keep"), "`export let` is still a symbol");
}

// --- enclosing-sweep call attribution under nesting -------------------------
{
  // outer fn contains an inner module-nested fn; calls must attribute to the
  // innermost enclosing symbol, and disjoint siblings must not bleed.
  const src = [
    "let a = () -> Int { p() }",       // a -> p
    "module M {",
    "  let b = () -> Int { q() }",     // b -> q  (module-nested)
    "}",
    "let c = () -> Int { r() }",       // c -> r  (sibling after module)
  ].join("\n");
  const ex = extractFile(src);
  const at = (callee) => (ex.calls.find((x) => x.callee === callee) || {}).caller;
  eq(at("p"), "a", "call p attributed to a");
  eq(at("q"), "b", "call q attributed to module-nested b (innermost)");
  eq(at("r"), "c", "call r attributed to c (no sibling bleed after module close)");
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
  const inc = idx.incomingCalls("twice");
  eq(inc.map((c) => c.caller).sort(), ["combo", "run"], "incomingCalls(twice) spans files");
  ok(inc.every((c) => c.sites.length >= 1 && c.sites[0].path && typeof c.sites[0].off === "number"), "incoming entries carry call-site offsets");
  // outgoing from combo: inc, twice
  const og = idx.outgoingCalls("combo");
  eq(og.map((c) => c.callee).sort(), ["inc", "twice"], "outgoingCalls(combo)");
  ok(og.every((c) => c.defined), "outgoing callees resolve to workspace symbols");
  ok(og.every((c) => c.sites.length >= 1 && c.sites[0].path === "/util.vibe"), "outgoing call-sites are in the caller's file");

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
