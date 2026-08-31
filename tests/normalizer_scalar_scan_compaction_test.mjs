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

function definitionCount(name) {
  return [...maskNonCode(source).matchAll(new RegExp(`\\bfn\\s+${name}\\s*\\(`, "g"))].length;
}

const scan = functionPartsIn(source, "dinsp_scan");
const marker = functionPartsIn(source, "dlh_marker_only_called_directly");
const assigned = functionPartsIn(source, "dlh_names_ever_assigned");
const collector = functionPartsIn(source, "collect_pat_binders");
const contains = functionPartsIn(source, "str_array_contains");

for (const kept of ["dinsp_scan", "collect_pat_binders", "str_array_contains"]) assert.equal(definitionCount(kept), 1, `${kept} unique`);
for (const removed of ["dlh_mocd_scan", "dlh_naa_scan", "dlh_pat_binds", "relabel_pat_binds", "dlh_contains", "relabel_shadowed", "expr_has_labeled_arg", "arr_has_labeled_arg", "pairs_have_labeled_arg", "arms_have_labeled_arg"]) assert.equal(definitionCount(removed), 0, `${removed} removed`);
assertCanonicalBody(marker, "!dinsp_scan(expr, 4, marker)", "direct marker wrapper");
assertCanonicalBody(assigned, `let mut i = 0 let mut found = false while !found && i < Array::length(names) { found = dinsp_scan(expr, 5, Array::get(names, i)) i = i + 1 } found`, "many-name scalar assignment wrapper");
assert.doesNotMatch(marker.text + assigned.text + scan.text, /Array\[Bool\]|\[\s*false\s*\]|Array::set|expr_children|->\s*Option|->\s*\(/);

const modeArms = [
  [
    { role: "inspect-call", pattern: "ECall(callee, args, _)", body: `match callee { EIdent(n, _) => n == "inspect" && Array::length(args) == 2, _ => false }` },
    { role: "inspect-default", pattern: "_", body: "false" }
  ],
  [
    { role: "let-binder", pattern: "ELet(n, _, _, _)", body: `n == "inspect"` },
    { role: "letrec-binder", pattern: "ELetRec(n, _, _)", body: `n == "inspect"` },
    { role: "letmut-binder", pattern: "ELetMut(n, _, _, _)", body: `n == "inspect"` },
    { role: "for-binder", pattern: "EForIn(v, _, _, _)", body: `v == "inspect"` },
    { role: "parameter-binder", pattern: "EFn(_, _, params, _, _, _)", body: `dinsp_params_bind(params, "inspect")` },
    { role: "match-binder", pattern: "EMatch(_, arms)", body: `dinsp_arms_bind(arms, "inspect")` },
    { role: "handle-binder", pattern: "EHandle(_, arms)", body: `dinsp_arms_bind(arms, "inspect")` },
    { role: "binder-default", pattern: "_", body: "false" }
  ],
  [
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
  ],
  [
    { role: "labeled-wrapper-self", pattern: "ELabeledArg(_, _, _)", body: "true" },
    { role: "labeled-default", pattern: "_", body: "false" }
  ],
  [
    { role: "marker-value", pattern: "EIdent(n, _)", body: "n == name" },
    { role: "marker-assign", pattern: "EAssign(n, _, _)", body: "n == name" },
    { role: "marker-assignop", pattern: "EAssignOp(n, _, _, _)", body: "n == name" },
    { role: "marker-default", pattern: "_", body: "false" }
  ],
  [
    { role: "captured-assign", pattern: "EAssign(n, _, _)", body: "n == name" },
    { role: "captured-assignop", pattern: "EAssignOp(n, _, _, _)", body: "n == name" },
    { role: "assignment-default", pattern: "_", body: "false" }
  ]
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
assert.equal(scanMatches.length, 7, "six mode leaf matches and one recursive match");
for (let mode = 0; mode < 6; mode += 1) assertArms(scanMatches[mode], modeArms[mode], `mode ${mode}`);
assertArms(scanMatches[6], recursiveArms, "recursive Expr descent");
const recursiveConstructors = scanMatches[6].map(({ pattern }) => pattern.match(/^([A-Z][A-Za-z0-9_]*)/)?.[1]);
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
const wrongChild = scan.body.replace("dinsp_scan(c, mode, name) || dinsp_scan(t, mode, name) || dinsp_scan(f, mode, name)", "dinsp_scan(t, mode, name) || dinsp_scan(c, mode, name) || dinsp_scan(f, mode, name)");
expectMutationFailure("swapped recursive child", () => assertArms(matchExprArms(wrongChild)[6], recursiveArms, "mutated Expr"));
const wrongDirect = scan.body.replace("ECall(callee, args, _) => if mode == 4 {", "ECall(callee, args, _) => if mode == 5 {");
expectMutationFailure("wrong direct-callee mode", () => assertArms(matchExprArms(wrongDirect)[6], recursiveArms, "mutated call"));
const wrongPat = collector.body.replace("collect_pat_binders(a, out)\n      collect_pat_binders(b, out)", "collect_pat_binders(b, out)\n      collect_pat_binders(a, out)");
expectMutationFailure("reversed POr binder order", () => assertArms(parseMatchAt(wrongPat, maskNonCode(wrongPat).search(/\bmatch\s+p\s*\{/)), expectedPatArms, "mutated Pat"));
expectMutationFailure("membership comparator", () => assert.equal(canonical(contains.body.replace("== val", "!= val")), canonical(membershipBody)));

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
