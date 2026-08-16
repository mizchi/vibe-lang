import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const normalizer = readFileSync(new URL("lib/@vibe/compiler/normalize/desugar_trait_dict.vibe", root), "utf8");
const detach = readFileSync(new URL("lib/@vibe/parser/ast_detach.vibe", root), "utf8");
const normalizeFacade = readFileSync(new URL("lib/@vibe/compiler/normalize/index.vpkg", root), "utf8");
const parserFacade = readFileSync(new URL("lib/@vibe/parser/index.vpkg", root), "utf8");

function maskNonCode(source) {
  const out = [...source];
  let string = false;
  let escaped = false;
  let comment = false;
  for (let i = 0; i < out.length; i++) {
    const c = source[i];
    const n = source[i + 1] ?? "";
    if (comment) {
      if (c === "\n") comment = false;
      else out[i] = " ";
    } else if (string) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') string = false;
      if (c !== "\n") out[i] = " ";
    } else if (c === "/" && n === "/") {
      comment = true;
      out[i] = out[i + 1] = " ";
      i++;
    } else if (c === '"') {
      string = true;
      out[i] = " ";
    }
  }
  return out.join("");
}

function functionBody(source, name) {
  const masked = maskNonCode(source);
  const match = new RegExp(`(?:export\\s+)?fn\\s+${name}\\s*\\(`).exec(masked);
  assert.ok(match, `${name} definition missing`);
  const open = masked.indexOf("{", match.index);
  assert.notEqual(open, -1, `${name} body missing`);
  let depth = 0;
  for (let i = open; i < masked.length; i++) {
    if (masked[i] === "{") depth++;
    else if (masked[i] === "}" && --depth === 0) return source.slice(open + 1, i);
  }
  assert.fail(`${name} body unterminated`);
}

function outerArms(source, name) {
  const body = functionBody(source, name);
  const masked = maskNonCode(body);
  const starts = [];
  let brace = 0;
  for (let i = 0; i < masked.length; i++) {
    if (masked[i] === "{") brace++;
    else if (masked[i] === "}") brace--;
    if (brace !== 1 || (i > 0 && masked[i - 1] !== "\n")) continue;
    const m = /^    ([A-Z][A-Za-z0-9_]*|_)(?:\([^\n]*\))? =>/.exec(masked.slice(i));
    if (m) starts.push({ name: m[1], index: i });
  }
  return new Map(starts.map((entry, i) => [entry.name, body.slice(entry.index, starts[i + 1]?.index ?? body.length)]));
}

function exactKeys(map, expected, label) {
  assert.deepEqual([...map.keys()].filter((x) => x !== "_").sort(), [...expected].sort(), label);
}

const ordinary = [
  ["optional_fill_args", "fn optional_fill_args(args: Array[Expr], flags: Array[Bool]) -> Array[Expr]"],
  ["reorder_labeled_args", "fn reorder_labeled_args(args: Array[Expr], param_labels: Array[String]) -> Option[Array[Expr]]"],
  ["strip_labeled_wrappers", "fn strip_labeled_wrappers(args: Array[Expr]) -> Array[Expr]"],
  ["strip_in_position_labels", "fn strip_in_position_labels(args: Array[Expr], labels: Array[String]) -> Array[Expr]"],
  ["relabel_expr", "fn relabel_expr(expr: Expr, tbl: Array[(String, Array[String])], shadows: Array[String]) -> Expr"],
  ["relabel_stmt", "fn relabel_stmt(stmt: Stmt, tbl: Array[(String, Array[String])]) -> Stmt"],
  ["desugar_labeled_args", "export fn desugar_labeled_args(stmts: Array[Stmt]) -> Unit"],
];
for (const [name, signature] of ordinary) {
  assert.ok(normalizer.includes(signature), signature);
  assert.doesNotMatch(functionBody(normalizer, name), /paired_|BinderAuthority|detach_stmts|located_program_binder_authority|callback|LabeledArgAuthorityWalk/);
}
assert.match(functionBody(normalizer, "desugar_labeled_args"), /stmt_has_labeled_arg/);
assert.doesNotMatch(functionBody(normalizer, "desugar_labeled_args"), /desugar_labeled_args_paired/);

for (const [name, result] of [["labeled_reorder_candidate", "Bool"], ["labeled_source_index", "Int"], ["label_matches_position", "Bool"]]) {
  assert.match(normalizer, new RegExp(`fn ${name}\\([^)]*\\) -> ${result}`));
  assert.doesNotMatch(functionBody(normalizer, name), /Some\(|None|ArrayBuilder|array_empty|callback/);
}

const callArm = outerArms(normalizer, "relabel_expr_paired").get("ECall");
assert.match(callArm, /let source = labeled_source_index\(rargs, Array::get\(labels, pi\)\)/);
assert.match(callArm, /Array::push\(reordered, Array::get\(rargs, source\)\)/);
assert.match(callArm, /Array::set\(node.children, pi \+ 1, Array::get\(original_children, source \+ 1\)\)/);
assert.match(callArm, /Array::get\(used, source\)/);
const promote = functionBody(normalizer, "paired_promote_wrapper");
assert.match(promote, /AuthorityExprLabeledArg/);
assert.match(promote, /Array::length\(binder_authority_node_slots\(wrapper\)\) == 0/);
assert.match(promote, /Array::length\(children\) == 1/);

assert.match(normalizeFacade, /normalize_labeled_args_with_binder_authority\(source: LocatedProgramBinderAuthority\)/);
assert.doesNotMatch(normalizeFacade, /normalize_labeled_args_with_binder_authority\([^)]*(BinderAuthorityNode|BinderAuthoritySlot|Array\[)/);
assert.match(parserFacade, /fn detach_stmts\(stmts: Array\[Stmt\]\) -> Array\[Stmt\]/);

const pats = ["PWild", "PBind", "PInt", "PFloat", "PString", "PBool", "PCtor", "PTuple", "POr", "PStruct"];
const types = ["TyName", "TyApp", "TyFn", "TyTuple", "TyUnit"];
const exprs = ["EInt", "EFloat", "EString", "EBool", "EIdent", "ETuple", "EArray", "ERecord", "EIf", "ELet", "ELetRec", "ELetMut", "EAssign", "EAssignOp", "ESeq", "EMatch", "EHandle", "EWhile", "ELoop", "EForIn", "ECall", "EBinOp", "EUnaryOp", "EFn", "EDot", "ELabeledArg", "EReturn", "EBreak", "EContinue", "EMap", "ESpread", "EStringInterp", "EUnit"];
const stmts = ["SLet", "SLetMut", "SEnum", "SSuberror", "SStruct", "STypeAlias", "STrait", "SImpl", "SExternLet", "SImport", "STest", "SBench", "SExample", "SExpr", "SExport", "SReExport", "SAliasDecl", "SQualifiedPatternRefs", "STestEffectRows", "SLetPat", "SModule", "SEffectDef", "SEffectSet", "SResource", "SFnDecl"];
exactKeys(outerArms(detach, "detach_pat"), pats, "10 Pat detachment arms");
exactKeys(outerArms(detach, "detach_type_expr"), types, "5 TypeExpr detachment arms");
exactKeys(outerArms(detach, "detach_expr"), exprs, "33 Expr detachment arms");
exactKeys(outerArms(detach, "detach_stmt"), stmts, "25 Stmt detachment arms");
for (const name of ["detach_pat", "detach_type_expr", "detach_expr", "detach_stmt"]) assert.doesNotMatch(functionBody(detach, name), /_ =>/);

const pairedPats = outerArms(normalizer, "paired_expect_pat");
exactKeys(pairedPats, pats, "10 paired Pat arms");
assert.match(pairedPats.get("POr"), /paired_poison/);
const pairedExprs = outerArms(normalizer, "relabel_expr_paired");
exactKeys(pairedExprs, exprs, "33 paired Expr arms");
assert.match(pairedExprs.get("ELoop"), /paired_poison[\s\S]*relabel_expr\(expr, tbl, shadows\)/);
for (const name of ["EMatch", "EHandle"]) assert.match(pairedExprs.get(name), /node, 0[\s\S]*1 \+ i \* 2[\s\S]*2 \+ i \* 2/);

const pairedStmts = outerArms(normalizer, "relabel_stmt_paired");
exactKeys(pairedStmts, ["SLet", "SLetMut", "STest", "SBench", "SExample", "SExpr", "SExternLet", "SImport", "SAliasDecl", "STypeAlias", "SEffectSet", "SResource", "SExport", "SReExport", "SQualifiedPatternRefs", "STestEffectRows"], "paired supported Stmt arms");
assert.match(pairedStmts.get("SExample"), /AuthorityStmtExample[\s\S]*relabel_expr_paired_child/);
assert.match(pairedStmts.get("_"), /paired_poison[\s\S]*relabel_stmt/);

const driver = functionBody(normalizer, "desugar_labeled_args_paired");
assert.match(driver, /Array::length\(roots\) != Array::length\(stmts\)[\s\S]*paired_poison/);
assert.match(driver, /let sentinel = BinderAuthorityNode/);
assert.match(driver, /while i < Array::length\(stmts\)/);
assert.match(driver, /else \{\s*sentinel\s*\}/);
assert.doesNotMatch(driver, /relabel_stmt\(/);
assert.doesNotMatch(normalizer, /Option\[LabeledArgAuthorityWalk\]|struct LabeledArgAuthorityWalk/);

console.log("labeled binder authority structure: ok");
