import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const detach = readFileSync(new URL("lib/@vibe/parser/ast_detach.vibe", root), "utf8");
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

assert.match(parserFacade, /fn detach_stmts\(stmts: Array\[Stmt\]\) -> Array\[Stmt\]/);

const pats = ["PWild", "PBind", "PInt", "PFloat", "PString", "PBool", "PCtor", "PTuple", "POr", "PStruct"];
const types = ["TyName", "TyApp", "TyFn", "TyTuple", "TyUnit"];
const exprs = ["EInt", "EFloat", "EString", "EBool", "EIdent", "ETuple", "EArray", "ERecord", "EIf", "ELet", "ELetRec", "ELetMut", "EAssign", "EAssignOp", "ESeq", "EMatch", "EHandle", "EWhile", "ELoop", "EForIn", "ECall", "EBinOp", "EUnaryOp", "EFn", "EDot", "ELabeledArg", "EReturn", "EBreak", "EContinue", "EMap", "ESpread", "EStringInterp", "EUnit"];
const stmts = ["SLet", "SLetMut", "SEnum", "SSuberror", "SStruct", "STypeAlias", "STrait", "SImpl", "SExternLet", "SImport", "STest", "SBench", "SExample", "SExpr", "SExport", "SReExport", "SReExportSourceBoundary", "SAliasDecl", "SQualifiedPatternRefs", "STestEffectRows", "SLetPat", "SModule", "SEffectDef", "SEffectSet", "SResource", "SFnDecl"];
exactKeys(outerArms(detach, "detach_pat"), pats, "10 Pat detachment arms");
exactKeys(outerArms(detach, "detach_type_expr"), types, "5 TypeExpr detachment arms");
exactKeys(outerArms(detach, "detach_expr"), exprs, "33 Expr detachment arms");
exactKeys(outerArms(detach, "detach_stmt"), stmts, "26 Stmt detachment arms");
for (const name of ["detach_pat", "detach_type_expr", "detach_expr", "detach_stmt"]) assert.doesNotMatch(functionBody(detach, name), /_ =>/);

console.log("parser detachment structure: ok");
