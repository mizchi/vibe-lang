#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs.readFileSync(new URL("../lib/@vibe/compiler/normalize/desugar_trait_dict.vibe", import.meta.url), "utf8");
const astContract = fs.readFileSync(new URL("../lib/@vibe/ast/index.vpkg", import.meta.url), "utf8");

// Mask non-code without changing offsets. Search indexes from this text are safe
// to use against the original source; this is the regression boundary that the
// rejected first oracle violated by deleting comment bytes.
function maskNonCode(text, maskStrings = true) {
  const out = [...text];
  let state = "code";
  let escaped = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (state === "string") {
      if (maskStrings && ch !== "\n") out[i] = " ";
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') state = "code";
    } else if (state === "comment") {
      if (ch === "\n") state = "code";
      else out[i] = " ";
    } else if (ch === '"') {
      state = "string";
      if (maskStrings) out[i] = " ";
    } else if (ch === "/" && next === "/") {
      state = "comment";
      out[i] = " ";
      out[i + 1] = " ";
      i += 1;
    }
  }
  return out.join("");
}

function balanced(text, openIndex) {
  assert.equal(text[openIndex], "{", `expected { at ${openIndex}`);
  let depth = 0;
  let state = "code";
  let escaped = false;
  for (let i = openIndex; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (state === "string") {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') state = "code";
      continue;
    }
    if (state === "comment") {
      if (ch === "\n") state = "code";
      continue;
    }
    if (ch === '"') state = "string";
    else if (ch === "/" && next === "/") { state = "comment"; i += 1; }
    else if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return { body: text.slice(openIndex + 1, i), end: i + 1 };
    }
  }
  assert.fail(`unterminated block at ${openIndex}`);
}

function canonical(text) {
  return maskNonCode(text, false).replace(/\s+/g, " ").trim();
}

function splitTopLevel(text, separator) {
  const parts = [];
  const stack = [];
  const closing = { "(": ")", "[": "]", "{": "}" };
  let state = "code";
  let escaped = false;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (state === "string") {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') state = "code";
      continue;
    }
    if (state === "comment") {
      if (ch === "\n") state = "code";
      continue;
    }
    if (ch === '"') state = "string";
    else if (ch === "/" && next === "/") { state = "comment"; i += 1; }
    else if (closing[ch]) stack.push(closing[ch]);
    else if (stack.at(-1) === ch) stack.pop();
    else if (ch === separator && stack.length === 0) {
      if (canonical(text.slice(start, i))) parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  assert.equal(stack.length, 0, `unbalanced text split on ${separator}`);
  if (canonical(text.slice(start))) parts.push(text.slice(start));
  return parts;
}

function splitArrow(arm) {
  const masked = maskNonCode(arm);
  const stack = [];
  const closing = { "(": ")", "[": "]", "{": "}" };
  for (let i = 0; i + 1 < masked.length; i += 1) {
    const ch = masked[i];
    if (closing[ch]) stack.push(closing[ch]);
    else if (stack.at(-1) === ch) stack.pop();
    else if (ch === "=" && masked[i + 1] === ">" && stack.length === 0) {
      return { pattern: canonical(arm.slice(0, i)), body: canonical(arm.slice(i + 2)) };
    }
  }
  assert.fail(`missing top-level => in ${canonical(arm)}`);
}

function functionPartsIn(text, name) {
  const masked = maskNonCode(text);
  const start = masked.indexOf(`fn ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  const open = masked.indexOf("{", start);
  const block = balanced(text, open);
  return { header: canonical(text.slice(start, open)), body: block.body, text: text.slice(start, block.end) };
}

function parseMatchAt(text, matchIndex) {
  const open = maskNonCode(text).indexOf("{", matchIndex);
  assert.notEqual(open, -1, "match must have a code brace");
  return splitTopLevel(balanced(text, open).body, ",").map(splitArrow);
}

function matchExprArms(body) {
  const masked = maskNonCode(body);
  const re = /\bmatch\s+expr\s*\{/g;
  const result = [];
  let found;
  while ((found = re.exec(masked)) !== null) result.push(parseMatchAt(body, found.index));
  return result;
}

function enumConstructors(name) {
  const masked = maskNonCode(astContract);
  const start = masked.indexOf(`export enum ${name}`);
  assert.notEqual(start, -1, `${name} enum must exist`);
  const open = masked.indexOf("{", start);
  return splitTopLevel(balanced(astContract, open).body, ";").map((decl) => {
    const found = canonical(decl).match(/^([A-Z][A-Za-z0-9_]*)/);
    assert.ok(found, `constructor missing in ${decl}`);
    return found[1];
  });
}

function assertArms(actual, expected, label) {
  assert.equal(actual.length, expected.length, `${label}: arm count`);
  for (let i = 0; i < expected.length; i += 1) {
    assert.ok(expected[i].role, `${label}[${i}] needs a semantic role`);
    assert.equal(actual[i].pattern, canonical(expected[i].pattern), `${label}/${expected[i].role}: pattern`);
    assert.equal(actual[i].body, canonical(expected[i].body), `${label}/${expected[i].role}: ordered body`);
  }
}

function assertCanonicalBody(part, expected, label) {
  assert.equal(canonical(part.body), canonical(expected), label);
}

// The mode-7 arm's byte range in `dinsp_scan`'s body, so a cell write can be
// required to live inside it rather than merely to exist somewhere.
function censusArmText(body) {
  const masked = maskNonCode(body);
  const head = masked.indexOf("mode == 7");
  assert.notEqual(head, -1, "mode 7 arm must exist");
  const open = masked.indexOf("{", head);
  assert.notEqual(open, -1, "mode 7 arm must have a block");
  const block = balanced(body, open);
  return { start: open, end: block.end };
}

function definitionCount(name) {
  return [...maskNonCode(source).matchAll(new RegExp(`\\bfn\\s+${name}\\s*\\(`, "g"))].length;
}

const scan = functionPartsIn(source, "dinsp_scan");
const hereUses = functionPartsIn(source, "dinsp_here_uses");
const hereBinds = functionPartsIn(source, "dinsp_here_binds");
const marker = functionPartsIn(source, "dlh_marker_only_called_directly");
const assigned = functionPartsIn(source, "dlh_names_ever_assigned");
const collector = functionPartsIn(source, "collect_pat_binders");
const contains = functionPartsIn(source, "str_array_contains");

for (const kept of ["dinsp_scan", "dinsp_here_uses", "dinsp_here_binds", "collect_pat_binders", "str_array_contains"]) assert.equal(definitionCount(kept), 1, `${kept} unique`);
for (const removed of ["dlh_mocd_scan", "dlh_naa_scan", "dlh_pat_binds", "relabel_pat_binds", "dlh_contains", "relabel_shadowed", "expr_has_labeled_arg", "arr_has_labeled_arg", "pairs_have_labeled_arg", "arms_have_labeled_arg"]) assert.equal(definitionCount(removed), 0, `${removed} removed`);
assertCanonicalBody(marker, "!dinsp_scan(expr, 4, marker)", "direct marker wrapper");
assertCanonicalBody(assigned, `let mut i = 0 let mut found = false while !found && i < Array::length(names) { found = dinsp_scan(expr, 5, Array::get(names, i)) i = i + 1 } found`, "many-name scalar assignment wrapper");

// The compaction property. `Array::set` is NOT in the blanket list any more:
// #2537 gave mode 7 a module-level `Int` pair cell so ONE walk answers both
// "binds inspect?" and "calls inspect?", replacing two walks -- reverting that
// to keep the scan cell-free would cost the walk it saves. So the cell is
// allowed, and scoped instead: every `Array::set` in the scan must be inside
// the mode-7 arm and must target `dinsp_census_cell`. A cell introduced
// anywhere else, or a second cell, still fails.
assert.doesNotMatch(marker.text + assigned.text + scan.text, /Array\[Bool\]|\[\s*false\s*\]|expr_children|->\s*Option|->\s*\(/);
const censusArm = censusArmText(scan.body);
for (const [where, text] of [["marker wrapper", marker.text], ["assignment wrapper", assigned.text]]) {
  assert.doesNotMatch(text, /Array::set/, `${where} must stay cell-free`);
}
function assertCellDiscipline(body, label) {
  const arm = censusArmText(body);
  const sets = [...maskNonCode(body).matchAll(/Array::set\(([A-Za-z0-9_]+)/g)];
  assert.ok(sets.length > 0, `${label}: mode 7 records its census through a cell`);
  for (const found of sets) {
    assert.equal(found[1], "dinsp_census_cell", `${label}: the only cell the scan writes is the census cell`);
    assert.ok(found.index >= arm.start && found.index < arm.end, `${label}: every cell write is inside the mode 7 arm`);
  }
}
assertCellDiscipline(scan.body, "dinsp_scan");

// The LEAF matches, in source order. Modes 0 and 1 are not here: #2537 moved
// their predicates into `dinsp_here_uses` / `dinsp_here_binds` (asserted
// separately below) so mode 7 could answer both in ONE walk, and mode 7 itself
// has no `match expr` at all -- it calls those two and records the pair.
const modeArms = [
  { mode: 2, arms: [
    { role: "identifier", pattern: "EIdent(n, _)", body: "n == name" },
    { role: "let-name", pattern: "ELet(n, _, _, _)", body: "n == name" },
    { role: "letrec-name", pattern: "ELetRec(n, _, _)", body: "n == name" },
    { role: "letmut-name", pattern: "ELetMut(n, _, _, _)", body: "n == name" },
    { role: "assign-target", pattern: "EAssign(n, _, _)", body: "n == name" },
    { role: "assignop-target", pattern: "EAssignOp(n, _, _, _)", body: "n == name" },
    { role: "for-name", pattern: "EForIn(v, _, _, _)", body: "v == name" },
    { role: "parameter-name", pattern: "EFn(_, _, params, _, _, _)", body: "dinsp_params_bind(params, name)" },
    { role: "match-name", pattern: "EMatch(_, arms)", body: "dinsp_arms_bind(arms, name)" },
    { role: "handle-name", pattern: "EHandle(_, arms)", body: "dinsp_arms_bind(arms, name)" },
    { role: "mention-default", pattern: "_", body: "false" }
  ] },
  { mode: 3, arms: [
    { role: "labeled-wrapper-self", pattern: "ELabeledArg(_, _, _)", body: "true" },
    // #1952: a block-local `(a: Int, b?: Int)` is the second reason the
    // relabel walk can change a statement. Without this arm the statement was
    // skipped and the omitted argument reached the checker as an arity error.
    { role: "optional-parameter-lambda", pattern: "EFn(_, _, params, _, _, _)", body: "dinsp_params_optional(params)" },
    { role: "labeled-default", pattern: "_", body: "false" }
  ] },
  { mode: 4, arms: [
    { role: "marker-value", pattern: "EIdent(n, _)", body: "n == name" },
    { role: "marker-assign", pattern: "EAssign(n, _, _)", body: "n == name" },
    { role: "marker-assignop", pattern: "EAssignOp(n, _, _, _)", body: "n == name" },
    { role: "marker-default", pattern: "_", body: "false" }
  ] },
  // #2386: the third and last reason the relabel walk can change a statement
  // -- a call to a TOP-LEVEL optional-parameter fn by name. An omitted
  // optional leaves no syntactic trace at the call site, but the callee's name
  // is one, so this reads the same table the walk reads.
  { mode: 6, arms: [
    { role: "top-level-optional-callee", pattern: "ECall(callee, _, _)", body: `match callee { EIdent(n, _) => match optional_param_flags(n) { Some(_) => true, None => false }, _ => false }` },
    { role: "optional-call-default", pattern: "_", body: "false" }
  ] },
  // The `else`, i.e. mode 5.
  { mode: 5, arms: [
    { role: "captured-assign", pattern: "EAssign(n, _, _)", body: "n == name" },
    { role: "captured-assignop", pattern: "EAssignOp(n, _, _, _)", body: "n == name" },
    { role: "assignment-default", pattern: "_", body: "false" }
  ] }
];

// Modes 0 and 1, as their own predicates. Same arms they had inline, so
// splitting them out for the census cost no coverage.
const hereUsesArms = [
  { role: "inspect-call", pattern: "ECall(callee, args, _)", body: `match callee { EIdent(n, _) => n == "inspect" && Array::length(args) == 2, _ => false }` },
  { role: "inspect-default", pattern: "_", body: "false" }
];
const hereBindsArms = [
  { role: "let-binder", pattern: "ELet(n, _, _, _)", body: `n == "inspect"` },
  { role: "letrec-binder", pattern: "ELetRec(n, _, _)", body: `n == "inspect"` },
  { role: "letmut-binder", pattern: "ELetMut(n, _, _, _)", body: `n == "inspect"` },
  { role: "for-binder", pattern: "EForIn(v, _, _, _)", body: `v == "inspect"` },
  { role: "parameter-binder", pattern: "EFn(_, _, params, _, _, _)", body: `dinsp_params_bind(params, "inspect")` },
  { role: "match-binder", pattern: "EMatch(_, arms)", body: `dinsp_arms_bind(arms, "inspect")` },
  { role: "handle-binder", pattern: "EHandle(_, arms)", body: `dinsp_arms_bind(arms, "inspect")` },
  { role: "binder-default", pattern: "_", body: "false" }
];

const recursiveArms = [
  ["int-leaf", "EInt(_)", "false"], ["float-leaf", "EFloat(_)", "false"], ["string-leaf", "EString(_)", "false"], ["bool-leaf", "EBool(_)", "false"], ["unit-leaf", "EUnit", "false"], ["identifier-leaf", "EIdent(_, _)", "false"], ["interpolation-opaque", "EStringInterp(_)", "false"],
  ["tuple-items", "ETuple(items)", "dinsp_scan_list(items, mode, name)"], ["array-items", "EArray(items)", "dinsp_scan_list(items, mode, name)"], ["record-values", "ERecord(_, fields, _)", "dinsp_scan_fields(fields, mode, name)"], ["map-values", "EMap(fields)", "dinsp_scan_fields(fields, mode, name)"],
  ["if-condition-then-else", "EIf(c, t, f)", "dinsp_scan(c, mode, name) || dinsp_scan(t, mode, name) || dinsp_scan(f, mode, name)"], ["let-value-body", "ELet(_, v, b, _)", "dinsp_scan(v, mode, name) || dinsp_scan(b, mode, name)"], ["letrec-value-body", "ELetRec(_, v, b)", "dinsp_scan(v, mode, name) || dinsp_scan(b, mode, name)"], ["letmut-value-body", "ELetMut(_, v, b, _)", "dinsp_scan(v, mode, name) || dinsp_scan(b, mode, name)"], ["assign-value-continuation", "EAssign(_, v, b)", "dinsp_scan(v, mode, name) || dinsp_scan(b, mode, name)"], ["assignop-value-continuation", "EAssignOp(_, _, v, b)", "dinsp_scan(v, mode, name) || dinsp_scan(b, mode, name)"], ["sequence-head-tail", "ESeq(a, b)", "dinsp_scan(a, mode, name) || dinsp_scan(b, mode, name)"],
  ["match-scrutinee-arms", "EMatch(sc, arms)", "dinsp_scan(sc, mode, name) || dinsp_scan_arms(arms, mode, name)"], ["handle-scrutinee-arms", "EHandle(sc, arms)", "dinsp_scan(sc, mode, name) || dinsp_scan_arms(arms, mode, name)"], ["while-condition-body", "EWhile(c, b)", "dinsp_scan(c, mode, name) || dinsp_scan(b, mode, name)"], ["loop-initializers-body", "ELoop(params, b)", "dinsp_scan_fields(params, mode, name) || dinsp_scan(b, mode, name)"], ["for-iterable-body", "EForIn(_, _, it, b)", "dinsp_scan(it, mode, name) || dinsp_scan(b, mode, name)"],
  ["call-callee-then-args-with-direct-marker-exemption", "ECall(callee, args, _)", `if mode == 4 { match callee { EIdent(n, _) => if n == name { dinsp_scan_list(args, mode, name) } else { dinsp_scan(callee, mode, name) || dinsp_scan_list(args, mode, name) }, _ => dinsp_scan(callee, mode, name) || dinsp_scan_list(args, mode, name) } } else { dinsp_scan(callee, mode, name) || dinsp_scan_list(args, mode, name) }`],
  ["binary-left-right", "EBinOp(_, l, r, _)", "dinsp_scan(l, mode, name) || dinsp_scan(r, mode, name)"], ["unary-value", "EUnaryOp(_, v)", "dinsp_scan(v, mode, name)"], ["function-body", "EFn(_, _, _, _, _, body)", "dinsp_scan(body, mode, name)"], ["dot-object", "EDot(inner, _, _, _)", "dinsp_scan(inner, mode, name)"], ["labeled-child", "ELabeledArg(_, _, v)", "dinsp_scan(v, mode, name)"], ["return-value", "EReturn(v)", "dinsp_scan(v, mode, name)"], ["optional-break", "EBreak(opt)", "match opt { Some(v) => dinsp_scan(v, mode, name), None => false }"], ["continue-values", "EContinue(args)", "dinsp_scan_list(args, mode, name)"], ["spread-value", "ESpread(v)", "dinsp_scan(v, mode, name)"]
].map(([role, pattern, body]) => ({ role, pattern, body }));

const scanMatches = matchExprArms(scan.body);
// Driven by the list, not a literal: a new mode with its own `match expr` is
// covered by adding one entry above rather than by editing a number that no
// longer says what it counts. #2386 added mode 6 and the literal `7` here went
// stale for a week without anything noticing (#2538).
assert.equal(scanMatches.length, modeArms.length + 1, `${modeArms.length} mode leaf matches and one recursive match`);
modeArms.forEach(({ mode, arms }, i) => assertArms(scanMatches[i], arms, `mode ${mode}`));
assertArms(scanMatches[scanMatches.length - 1], recursiveArms, "recursive Expr descent");
assertArms(matchExprArms(hereUses.body)[0], hereUsesArms, "dinsp_here_uses");
assertArms(matchExprArms(hereBinds.body)[0], hereBindsArms, "dinsp_here_binds");
// Mode 7 is the census: both bits recorded as the walk finds them, and the
// walk stops early only once BOTH are known. Pinned exactly, because "records
// a bit somewhere" is what the cell exemption above would otherwise permit.
assert.equal(canonical(scan.body.slice(censusArm.start + 1, censusArm.end - 1)),
  canonical(`if dinsp_here_uses(expr) { Array::set(dinsp_census_cell, 0, 1) } else { () }
    if dinsp_here_binds(expr) { Array::set(dinsp_census_cell, 1, 1) } else { () }
    Array::get(dinsp_census_cell, 0) != 0 && Array::get(dinsp_census_cell, 1) != 0`),
  "mode 7 census body");
const recursiveConstructors = scanMatches[scanMatches.length - 1].map(({ pattern }) => pattern.match(/^([A-Z][A-Za-z0-9_]*)/)?.[1]);
assert.deepEqual(new Set(recursiveConstructors), new Set(enumConstructors("Expr")), "all current Expr constructors covered");
assert.equal(recursiveConstructors.length, new Set(recursiveConstructors).size, "no duplicate Expr arms");

const patIndex = maskNonCode(collector.body).search(/\bmatch\s+p\s*\{/);
assert.notEqual(patIndex, -1);
const patArms = parseMatchAt(collector.body, patIndex);
const expectedPatArms = [
  { role: "bind", pattern: "PBind(n)", body: "Array::push(out, n)" },
  { role: "constructor-index-order", pattern: "PCtor(_, args)", body: "{ let mut i = 0 while i < Array::length(args) { collect_pat_binders(Array::get(args, i), out) i = i + 1 } }" },
  { role: "tuple-index-order", pattern: "PTuple(elems)", body: "{ let mut i = 0 while i < Array::length(elems) { collect_pat_binders(Array::get(elems, i), out) i = i + 1 } }" },
  { role: "or-left-right", pattern: "POr(a, b)", body: "{ collect_pat_binders(a, out) collect_pat_binders(b, out) }" },
  { role: "struct-field-order", pattern: "PStruct(_, fields)", body: "{ let mut i = 0 while i < Array::length(fields) { let (_, fp) = Array::get(fields, i) collect_pat_binders(fp, out) i = i + 1 } }" },
  { role: "non-binding", pattern: "_", body: "()" }
];
assertArms(patArms, expectedPatArms, "collect_pat_binders");
assert.deepEqual(enumConstructors("Pat"), ["PWild", "PBind", "PInt", "PFloat", "PString", "PBool", "PCtor", "PTuple", "POr", "PStruct"], "current Pat inventory classified by exact arms plus leaf fallback");

assert.equal(contains.header, "fn str_array_contains(arr: Array[String], val: String) -> Bool");
const membershipBody = `let mut i = 0 let mut found = false while i < Array::length(arr) { if Array::get(arr, i) == val { found = true i = Array::length(arr) } else { i = i + 1 } } found`;
assertCanonicalBody(contains, membershipBody, "membership equality/early-exit loop");
const helperBodies = new Map([
  ["dinsp_scan_list", `let mut i = 0 let mut found = false while !found && i < Array::length(items) { found = dinsp_scan(Array::get(items, i), mode, name) i = i + 1 } found`],
  ["dinsp_scan_fields", `let mut i = 0 let mut found = false while !found && i < Array::length(fields) { let (_, v) = Array::get(fields, i) found = dinsp_scan(v, mode, name) i = i + 1 } found`],
  ["dinsp_scan_arms", `let mut i = 0 let mut found = false while !found && i < Array::length(arms) { let (_, v) = Array::get(arms, i) found = dinsp_scan(v, mode, name) i = i + 1 } found`]
]);
for (const [name, body] of helperBodies) assertCanonicalBody(functionPartsIn(source, name), body, `${name} exact ordered loop`);

function expectMutationFailure(label, check) {
  assert.throws(check, assert.AssertionError, `${label} must be rejected`);
}

// A mutation that matched nothing passes every assertion below while proving
// nothing -- the exact way a red test "passes" (AGENTS.md, "red test は
// 「変異が当たったこと」を先に検証する"). Measured instance in this repo: a
// multi-line order block meant one slice only ever grabbed its first line.
function mutate(text, from, to, label) {
  const out = typeof from === "string" ? text.replace(from, to) : text.replace(from, to);
  assert.notEqual(out, text, `${label}: the mutation matched nothing`);
  return out;
}
const wrongChild = mutate(scan.body, "dinsp_scan(c, mode, name) || dinsp_scan(t, mode, name) || dinsp_scan(f, mode, name)", "dinsp_scan(t, mode, name) || dinsp_scan(c, mode, name) || dinsp_scan(f, mode, name)", "swapped recursive child");
expectMutationFailure("swapped recursive child", () => assertArms(matchExprArms(wrongChild).at(-1), recursiveArms, "mutated Expr"));
const wrongDirect = mutate(scan.body, "ECall(callee, args, _) => if mode == 4 {", "ECall(callee, args, _) => if mode == 5 {", "wrong direct-callee mode");
expectMutationFailure("wrong direct-callee mode", () => assertArms(matchExprArms(wrongDirect).at(-1), recursiveArms, "mutated call"));
const wrongPat = mutate(collector.body, "collect_pat_binders(a, out)\n      collect_pat_binders(b, out)", "collect_pat_binders(b, out)\n      collect_pat_binders(a, out)", "reversed POr binder order");
expectMutationFailure("reversed POr binder order", () => assertArms(parseMatchAt(wrongPat, maskNonCode(wrongPat).search(/\bmatch\s+p\s*\{/)), expectedPatArms, "mutated Pat"));
expectMutationFailure("membership comparator", () => assert.equal(canonical(mutate(contains.body, "== val", "!= val", "membership comparator")), canonical(membershipBody)));

// #2538: the material #2386 and #2537 added, mutated. The exemption the cell
// rule grants is narrow, and these are what say so -- an exemption nobody can
// break is indistinguishable from no rule at all.
const strayCell = mutate(scan.body, "} else if mode == 2 {", "} else if mode == 2 {\n    Array::set(dinsp_census_cell, 0, 1)", "cell write outside the mode 7 arm");
expectMutationFailure("cell write outside the mode 7 arm", () => assertCellDiscipline(strayCell, "mutated stray"));
const otherCell = mutate(scan.body, "Array::set(dinsp_census_cell, 1, 1)", "Array::set(dinsp_other_cell, 1, 1)", "a second cell");
expectMutationFailure("a second cell", () => assertCellDiscipline(otherCell, "mutated other"));
const noCell = mutate(scan.body, /Array::set\(dinsp_census_cell, \d, 1\)/g, "()", "census recorded without the cell");
expectMutationFailure("census recorded without the cell", () => assertCellDiscipline(noCell, "mutated none"));
const halfCensus = mutate(scan.body, "Array::set(dinsp_census_cell, 1, 1)", "Array::set(dinsp_census_cell, 0, 1)", "census records one bit twice");
expectMutationFailure("census records one bit twice", () => {
  const arm = censusArmText(halfCensus);
  assert.equal(canonical(halfCensus.slice(arm.start + 1, arm.end - 1)),
    canonical(halfCensus.slice(censusArm.start + 1, censusArm.end - 1).replace("Array::set(dinsp_census_cell, 0, 1)", "KEEP")));
});
const droppedMode = mutate(scan.body, /\} else if mode == 6 \{[\s\S]*?\n  \} else \{/, "} else {", "a dropped mode");
expectMutationFailure("a dropped mode", () => assert.equal(matchExprArms(droppedMode).length, modeArms.length + 1));
const wrongOptionalArm = mutate(scan.body, "EFn(_, _, params, _, _, _) => dinsp_params_optional(params),", "EFn(_, _, params, _, _, _) => dinsp_params_bind(params, name),", "mode 3 optional-parameter arm");
expectMutationFailure("mode 3 optional-parameter arm", () => assertArms(matchExprArms(wrongOptionalArm)[1], modeArms[1].arms, "mutated mode 3"));

const synthetic = `fn probe(expr: Expr) -> Bool {
  let escaped = "quoted \\\" match expr { [ ( ) ] }"
  if true {
    // this deliberately long comment shifts indexes in a deleting comment stripper: {{{ [[[(())]]] }}}
    match expr {
      EInt(_) => false,
      ECall(_, _, _) => { let nested = ["}", "{"] false }
    }
  } else { false }
}`;
const syntheticBody = functionPartsIn(synthetic, "probe").body;
const syntheticMatches = matchExprArms(syntheticBody);
assert.equal(syntheticMatches.length, 1);
assert.deepEqual(syntheticMatches[0].map(({ pattern }) => pattern), ["EInt(_)", "ECall(_, _, _)"]);
function deletingStrip(text) { return text.replace(/\/\/[^\n]*/g, ""); }
expectMutationFailure("deleted-comment coordinate mismatch", () => {
  const brokenIndex = deletingStrip(syntheticBody).search(/\bmatch\s+expr\s*\{/);
  const broken = parseMatchAt(syntheticBody, brokenIndex);
  assert.deepEqual(broken.map(({ pattern }) => pattern), ["EInt(_)", "ECall(_, _, _)"]);
});
assert.equal(maskNonCode(syntheticBody).length, syntheticBody.length, "masking preserves every source offset");

console.log("normalizer scalar scan production structure: ok");
