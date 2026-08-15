import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const baseSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_base.vibe", import.meta.url)), "utf8");
const exprSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr.vibe", import.meta.url)), "utf8");
const coreSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_core.vibe", import.meta.url)), "utf8");
const dispatchSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_dispatch.vibe", import.meta.url)), "utf8");
const primarySource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_primary.vibe", import.meta.url)), "utf8");
const expandInterpSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/expand_interp.vibe", import.meta.url)), "utf8");
const parserSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser.vibe", import.meta.url)), "utf8");
const binderContextSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_binder_context.vibe", import.meta.url)), "utf8");
const binderAuthoritySource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_binder_authority.vibe", import.meta.url)), "utf8");
const parserContract = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/index.vpkg", import.meta.url)), "utf8");
const compilerManifest = readFileSync(fileURLToPath(new URL("../lib/@vibe/compiler/compiler_sources_manifest.tsv", import.meta.url)), "utf8");

function regexEscape(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Extract exactly one Vibe function body. Braces inside strings and line
// comments are ignored, so an assertion cannot accidentally inspect a later
// helper and turn a local fallback into a false green.
function functionBody(source, name) {
  const pattern = new RegExp(`(?:^|\\n)(?:export\\s+)?fn\\s+${regexEscape(name)}\\s*\\(`, "gm");
  const matches = [...source.matchAll(pattern)];
  assert.equal(matches.length, 1, `${name}: expected exactly one implementation`);
  const match = matches[0];
  const open = source.indexOf("{", match.index + match[0].length);
  assert.notEqual(open, -1, `${name}: missing function body`);

  let depth = 1;
  let inString = false;
  let inLineComment = false;
  for (let i = open + 1; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];
    if (inLineComment) {
      if (ch === "\n") inLineComment = false;
    } else if (inString) {
      if (ch === "\\") i += 1;
      else if (ch === '"') inString = false;
    } else if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 1;
    } else if (ch === '"') {
      inString = true;
    } else if (ch === "{") {
      depth += 1;
    } else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  assert.fail(`${name}: unterminated function body`);
}

function normalize(source) {
  return source.replace(/\s+/g, " ").trim();
}

// Trivia-aware token inventory used for constructor completeness. This is a
// deliberately small Vibe lexer: comments and strings are skipped, identifiers
// are retained, and balanced delimiters determine function/call scope.
function vibeTokens(source) {
  const out = [];
  for (let i = 0; i < source.length;) {
    const ch = source[i];
    if (/\s/.test(ch)) { i += 1; continue; }
    if (ch === "/" && source[i + 1] === "/") {
      i += 2;
      while (i < source.length && source[i] !== "\n") i += 1;
      continue;
    }
    if (ch === '"') {
      i += 1;
      while (i < source.length) {
        if (source[i] === "\\") i += 2;
        else if (source[i++] === '"') break;
      }
      continue;
    }
    if (/[A-Za-z_]/.test(ch)) {
      const start = i++;
      while (i < source.length && /[A-Za-z0-9_]/.test(source[i])) i += 1;
      out.push({ text: source.slice(start, i), start });
      continue;
    }
    const pair = source.slice(i, i + 2);
    if (["=>", "->", "::"].includes(pair)) {
      out.push({ text: pair, start: i }); i += 2;
    } else {
      out.push({ text: ch, start: i }); i += 1;
    }
  }
  return out;
}

function balancedEnd(tokens, open, left, right) {
  let depth = 0;
  for (let i = open; i < tokens.length; i += 1) {
    if (tokens[i].text === left) depth += 1;
    else if (tokens[i].text === right && --depth === 0) return i;
  }
  assert.fail(`unterminated balanced ${left}${right} at token ${open}`);
}

function efnInventory(file, source) {
  const tokens = vibeTokens(source);
  const functions = [];
  for (let i = 0; i + 2 < tokens.length; i += 1) {
    if (tokens[i].text !== "fn" || !/^[A-Za-z_]/.test(tokens[i + 1].text)) continue;
    let body = i + 2;
    while (body < tokens.length && tokens[body].text !== "{") body += 1;
    assert.ok(body < tokens.length, `${file}:${tokens[i + 1].text}: missing body`);
    const end = balancedEnd(tokens, body, "{", "}");
    functions.push({ name: tokens[i + 1].text, body, end });
    i = end;
  }
  const sites = [];
  for (let i = 0; i + 1 < tokens.length; i += 1) {
    if (tokens[i].text !== "EFn" || tokens[i + 1].text !== "(") continue;
    const fn = functions.find((entry) => entry.body < i && i < entry.end);
    assert.ok(fn, `${file}: EFn site outside a function at byte ${tokens[i].start}`);
    const close = balancedEnd(tokens, i + 1, "(", ")");
    let depth = 0;
    let args = 1;
    const heads = [];
    let needHead = true;
    for (let j = i + 2; j < close; j += 1) {
      const text = tokens[j].text;
      if (needHead && !["(", "[", "{"].includes(text)) { heads.push(text); needHead = false; }
      if (["(", "[", "{"].includes(text)) depth += 1;
      else if ([")", "]", "}"].includes(text)) depth -= 1;
      else if (text === "," && depth === 0) { args += 1; needHead = true; }
    }
    assert.equal(args, 6, `${file}:${fn.name}: EFn must retain six balanced arguments`);
    sites.push({ file, fn: fn.name, shape: heads.join(",") });
    i = close;
  }
  return sites;
}

function assertBody(source, name, required, forbidden = []) {
  const body = functionBody(source, name);
  for (const needle of required) {
    assert.ok(body.includes(needle), `${name}: missing contextual call/text: ${needle}`);
  }
  for (const needle of forbidden) {
    assert.ok(!body.includes(needle), `${name}: legacy fallback is forbidden: ${needle}`);
  }
}

function assertContextual(source, name, required, forbidden = []) {
  const declaration = new RegExp(`(?:^|\\n)(?:export\\s+)?fn\\s+${regexEscape(name)}\\s*\\([^\\n]*context: Option\\[ParserBinderContext\\]`, "m");
  assert.match(source, declaration, `${name}: missing explicit untrusted context parameter`);
  assertBody(source, name, required, forbidden);
}

function assertNoneWrapper(source, name, exactDelegation) {
  const body = functionBody(source, name);
  assert.equal(normalize(body), normalize(exactDelegation), `${name}: wrapper must delegate exactly None`);
  assert.ok(!body.includes("Some(ParserBinderContext"), `${name}: compatibility wrapper must not mint context`);
}

test("balanced-token inventory classifies every production EFn site", () => {
  const files = new Map([
    ["expand_interp.vibe", expandInterpSource],
    ["parser.vibe", parserSource],
    ["parser_expr.vibe", exprSource],
    ["parser_expr_core.vibe", coreSource],
    ["parser_expr_dispatch.vibe", dispatchSource],
    ["parser_expr_primary.vibe", primarySource],
  ]);
  const expected = new Map([
    ["expand_interp.vibe:resolve_expr", [2, "slot-preserving reconstruction"]],
    ["parser.vibe:parse_impl_methods", [2, "deliberately ineligible"]],
    ["parser_expr.vibe:apply_generic_fn_annotation", [2, "slot-preserving reconstruction"]],
    ["parser_expr.vibe:apply_value_bracket_type_params", [3, "slot-preserving reconstruction"]],
    ["parser_expr.vibe:parse_fn_main_stmt", [1, "source-captured"]],
    ["parser_expr.vibe:parse_fn_wasm_body", [1, "source-captured"]],
    ["parser_expr.vibe:parse_fn_stmt_general", [1, "source-captured"]],
    ["parser_expr.vibe:lower_fn_decl_stmt_with_binder_context", [2, "slot-preserving reconstruction"]],
    ["parser_expr_core.vibe:parse_call_arg", [1, "source-captured"]],
    ["parser_expr_core.vibe:wrap_placeholder_arg", [1, "synthetic-captured"]],
    ["parser_expr_dispatch.vibe:ascribe_wrap", [1, "synthetic-captured"]],
    ["parser_expr_dispatch.vibe:distribute_local_fn_ann", [2, "slot-preserving reconstruction"]],
    ["parser_expr_dispatch.vibe:apply_local_let_tp", [2, "slot-preserving reconstruction"]],
    ["parser_expr_dispatch.vibe:apply_block_step", [1, "source-captured"]],
    ["parser_expr_dispatch.vibe:parse_impl_dispatch_with_binder_context", [2, "source-captured"]],
    ["parser_expr_primary.vibe:map_expr_offsets", [2, "slot-preserving reconstruction"]],
    ["parser_expr_primary.vibe:desugar_loop_body", [1, "slot-preserving reconstruction"]],
    ["parser_expr_primary.vibe:parse_generic_fn_primary", [2, "source-captured"]],
    ["parser_expr_primary.vibe:parse_paren_lambda_primary", [9, "source-captured"]],
  ]);
  const actual = new Map();
  for (const [file, source] of files) {
    for (const site of efnInventory(file, source)) {
      assert.ok(site.shape.length > 0, `${file}:${site.fn}: missing balanced argument shape`);
      const key = `${file}:${site.fn}`;
      actual.set(key, (actual.get(key) ?? 0) + 1);
    }
  }
  assert.deepEqual([...actual.keys()].sort(), [...expected.keys()].sort(), "new EFn functions require explicit classification");
  for (const [key, count] of actual) {
    const [expectedCount, classification] = expected.get(key);
    assert.equal(count, expectedCount, `${key}: constructor/pattern site inventory drift`);
    assert.ok(["source-captured", "synthetic-captured", "slot-preserving reconstruction", "deliberately ineligible"].includes(classification));
  }
});

test("B2 expression helper bodies carry context without private duplicate wrappers", () => {
  assertContextual(exprSource, "parse_let_type_params", [], ["parse_let_type_params_with_binder_context"]);
  assertContextual(exprSource, "parse_let_annotation", [
    "parse_let_type_params(tokens, pos + 1, context)",
  ], ["parse_let_type_params_with_binder_context"]);
  assertContextual(exprSource, "parse_value_bracket_header", [
    "parse_let_type_params(tokens, pos + 1, context)",
  ], ["parse_let_type_params_with_binder_context"]);
  assertContextual(exprSource, "parse_let_stmt_with_binder_context", [
    "parse_binding_name_with_binder_context(tokens, pos + 1, context)",
    "parse_binding_name_with_binder_context(tokens, pos, context)",
    "parse_pattern_with_binder_context(tokens, pos, context)",
    "parse_let_annotation(tokens, name_next + 1, context)",
    "parse_value_bracket_header(tokens, ep, context)",
    "parse_impl_with_binder_context(tokens, starts, ep, 0, context)",
  ], [
    "parse_binding_name(tokens,",
    "parse_pattern(tokens,",
    "parse_impl(tokens,",
  ]);
  assertContextual(exprSource, "parse_fn_name", [
    "parse_binding_name_with_binder_context(tokens, pos, context)",
  ], ["parse_binding_name(tokens,"]);
  assertContextual(exprSource, "parse_fn_signature_with_binder_context", [
    "parse_fn_name(tokens, pos, context)",
    "parse_value_bracket_header(tokens, name_next, context)",
    "parse_param_list_with_binder_context(tokens, lp, context)",
    "parse_impl_with_binder_context(tokens, [",
  ], [
    "parse_fn_name_with_binder_context",
    "parse_param_list(tokens,",
    "parse_impl(tokens,",
  ]);
  assertBody(exprSource, "parse_fn_signature", [
    "parse_fn_signature_with_binder_context(tokens, pos, None, None)",
  ], ["Some(ParserBinderContext"]);
  assertContextual(exprSource, "parse_fn_main_stmt", [
    "parse_impl_with_binder_context(tokens, starts, br, mode_block, context)",
  ], ["parse_impl(tokens,"]);
  assertContextual(exprSource, "parse_fn_stmt_with_binder_context", [
    "parse_fn_main_stmt(tokens, starts, pos, exported, context)",
    "parse_fn_stmt_general(tokens, starts, pos, exported, context)",
  ], [
    "parse_fn_main_stmt_with_binder_context",
    "parse_fn_stmt_general_with_binder_context",
  ]);
  assertContextual(exprSource, "parse_fn_stmt_general", [
    "parse_fn_signature_with_binder_context(tokens, pos, context, contract_rows)",
    "parse_impl_with_binder_context(tokens, starts, br, mode_block, context)",
  ], [
    "parse_fn_signature(tokens,",
    "parse_impl(tokens,",
  ]);
});

test("B2 top-level helper bodies carry context and ordinary entries pass None", () => {
  assertContextual(parserSource, "parse_test_stmt", ["parse_impl_with_binder_context(tokens, starts, br, parser_mode_block, context)"], ["parse_impl(tokens,"]);
  assertContextual(parserSource, "parse_example_stmt", ["parse_impl_with_binder_context(tokens, starts, br, parser_mode_block, context)"], ["parse_impl(tokens,"]);
  assertContextual(parserSource, "parse_bench_stmt", ["parse_impl_with_binder_context(tokens, starts, br, parser_mode_block, context)"], ["parse_impl(tokens,"]);
  assertContextual(parserSource, "parse_import_items_rest", [
    "parse_import_item_with_binder_context(tokens, pos + 1, context)",
    "parse_import_items_rest(tokens, next, b, context)",
  ], ["parse_import_item(tokens,"]);
  assertContextual(parserSource, "parse_import_items", [
    "parse_import_item_with_binder_context(tokens, pos, context)",
    "parse_import_items_rest(tokens, next, b, context)",
  ], ["parse_import_item(tokens,"]);
  assertContextual(parserSource, "parse_qualified_import_tail", ["parse_import_items(tokens, br, context)"], ["parse_import_items_with_binder_context"]);
  assertContextual(parserSource, "parse_import_path_tail", [
    "parse_qualified_import_tail(tokens, bp + 2, path, mod_name, context)",
    "parse_import_items(tokens, br, context)",
  ], [
    "parse_qualified_import_tail_with_binder_context",
    "parse_import_items_with_binder_context",
  ]);
  assertContextual(parserSource, "parse_import_stmt", [
    "parse_import_path_tail(tokens, bp, path, context)",
    "parse_import_path_tail(tokens, pos + 1, name, context)",
  ], ["parse_import_path_tail_with_binder_context"]);
  assertContextual(parserSource, "parse_toplevel_struct_fields_rest", [
    "parse_struct_field_with_binder_context(tokens, pos + 1, context)",
    "parse_toplevel_struct_fields_rest(tokens, next, b, mb, context)",
  ], ["parse_struct_field(tokens,"]);
  assertContextual(parserSource, "parse_toplevel_struct_fields", [
    "parse_struct_field_with_binder_context(tokens, pos, context)",
    "parse_toplevel_struct_fields_rest(tokens, next, b, mb, context)",
  ], ["parse_struct_field(tokens,"]);
  assertContextual(parserSource, "parse_toplevel_struct_stmt", [
    "parse_tparam_names_with_binder_context(tokens, pos + 1, context)",
    "parse_toplevel_struct_fields(tokens, br, context)",
  ], ["parse_tparam_names(tokens,"]);
  assertContextual(parserSource, "parse_effectset_stmt", ["parse_binding_name_with_binder_context(tokens, pos, context)"], ["parse_binding_name(tokens,"]);

  // Intentional allowlist: the resource kind after ':' is a reference, not a
  // binder. Legacy parse_binding_name is allowed only at that exact call.
  assertContextual(parserSource, "parse_resource_stmt", ["let (kind, end) = parse_binding_name(tokens, cp)"], ["parse_binding_name(tokens, pos)"]);

  assertContextual(parserSource, "parse_export_stmt", [
    "parse_let_stmt_with_binder_context(tokens, starts, pos + 1, true, context)",
    "parse_enum_stmt_with_binder_context(tokens, pos + 1, true, context)",
    "parse_suberror_stmt_with_binder_context(tokens, pos + 1, true, context)",
    "parse_toplevel_struct_stmt(tokens, pos + 1, true, context)",
    "parse_fn_stmt_with_binder_context(tokens, starts, pos + 1, true, context)",
    "parse_effect_stmt_with_binder_context(tokens, pos + 1, true, context)",
    "parse_effectset_stmt(tokens, pos + 1, true, context)",
    "parse_type_alias_stmt_with_binder_context(tokens, pos + 1, true, context)",
    "parse_trait_stmt_with_binder_context(tokens, pos + 1, true, context)",
    "parse_import_items(tokens, br, None)",
  ], [
    "parse_let_stmt(tokens,",
    "parse_fn_stmt(tokens,",
    "parse_enum_stmt(tokens,",
    "parse_suberror_stmt(tokens,",
    "parse_effect_stmt(tokens,",
    "parse_type_alias_stmt(tokens,",
    "parse_trait_stmt(tokens,",
    "parse_import_items(tokens, br, context)",
  ]);
  assert.equal((functionBody(parserSource, "parse_export_stmt").match(/parse_import_items\(tokens, br, None\)/g) ?? []).length, 2, "both relative re-export path forms must suppress local binder capture");
  assertContextual(parserSource, "parse_percent_symbol_name", [], ["parse_percent_symbol_name_with_binder_context"]);
  assertContextual(parserSource, "parse_extern_let_stmt", ['parse_percent_symbol_name(tokens, lp, "extern symbol name", context)'], ["parse_percent_symbol_name_with_binder_context"]);

  assertContextual(parserSource, "parse_stmt_preserving_with_binder_context", [
    "TLet => parse_let_stmt_with_binder_context",
    "_ => parse_export_stmt(tokens, starts, pos + 1, context)",
    "TImport => parse_import_stmt(tokens, pos + 1, context)",
    "TTest => parse_test_stmt(tokens, starts, pos + 1, context)",
    "TExample => parse_example_stmt(tokens, starts, pos + 1, context)",
    "TBench => parse_bench_stmt(tokens, starts, pos + 1, context)",
    "TFn => parse_fn_stmt_with_binder_context",
    "TEnum => parse_enum_stmt_with_binder_context",
    "TSuberror => parse_suberror_stmt_with_binder_context",
    "TStruct => parse_toplevel_struct_stmt(tokens, pos + 1, false, context)",
    "TType => parse_type_alias_stmt_with_binder_context",
    "TTrait => parse_trait_stmt_with_binder_context",
    '"effect" => parse_effect_stmt_with_binder_context',
    '"effectset" => parse_effectset_stmt(tokens, pos + 1, false, context)',
    '"resource" => parse_resource_stmt(tokens, pos + 1, context)',
    '"extern" => parse_extern_let_stmt(tokens, pos + 1, context)',
  ], [
    "parse_let_stmt(tokens,",
    "parse_export_stmt(tokens, starts, pos + 1)",
    "parse_import_stmt(tokens, pos + 1)",
    "parse_test_stmt(tokens, starts, pos + 1)",
    "parse_fn_stmt(tokens,",
    "parse_suberror_stmt(tokens,",
    "parse_type_alias_stmt(tokens,",
    "parse_trait_stmt(tokens,",
    "parse_effect_stmt(tokens,",
    "parse_impl(tokens,",
  ]);
  assertNoneWrapper(parserSource, "parse_stmt_preserving", "parse_stmt_preserving_with_binder_context(tokens, starts, pos, None)");
  assertContextual(parserSource, "parse_stmt_with_binder_context", ["parse_stmt_preserving_with_binder_context(tokens, starts, pos, context)"], ["parse_stmt_preserving(tokens,"]);

  assertContextual(parserSource, "parse_impl_methods", [
    "parse_impl_with_binder_context(tokens, [",
    "], p + 1, 0, context)",
  ], [
    "parse_expr(tokens,",
    "parse_impl(tokens,",
  ]);
  for (const ordinaryProgram of ["parse_program_preserving", "parse_program_recovering"]) {
    assertBody(parserSource, ordinaryProgram, [
      "parse_impl_methods(tokens, hp_d, simpl_d, None)",
      "parse_impl_methods(tokens, hp, simpl, None)",
    ], [
      "parse_impl_methods(tokens, hp_d, simpl_d, context)",
      "parse_impl_methods(tokens, hp, simpl, context)",
    ]);
  }

  assertContextual(parserSource, "parse_program_located_with_context_impl", [
    "parse_impl_stmt_dispatch_with_binder_context(tokens, dnext + 1, context)",
    "parse_impl_methods(tokens, hp_d, simpl_d, context)",
    "parse_impl_stmt_dispatch_with_binder_context(tokens, pos + 1, context)",
    "parse_impl_methods(tokens, hp, simpl, context)",
    "parse_stmt_with_binder_context(tokens, starts, dnext, context)",
    "parse_stmt_with_binder_context(tokens, starts, pos, context)",
  ], [
    "parse_impl_stmt_dispatch(tokens,",
    "parse_impl_methods(tokens, hp_d, simpl_d)",
    "parse_impl_methods(tokens, hp, simpl)",
    "parse_stmt(tokens,",
  ]);

  assertNoneWrapper(parserSource, "parse_program_located", "parse_program_located_with_context_impl(tokens, starts, source, None).0");
  assertContextual(parserSource, "parse_program_located_with_untrusted_binder_context", ["parse_program_located_with_context_impl(tokens, starts, source, context)"], ["ParserBinderContext::{"]);
  // Compatibility entry remains authority-free; only the source-owning entry
  // may mint a context with exact start/end tables.
  assertBody(parserSource, "parse_program_located_with_binder_context", ["parse_program_located_with_context_impl(tokens, starts, source, None).0"], ["Some(ParserBinderContext::{", "binder_capture_context"]);
});

test("atomic binder authority is source-owned, validated, fail-closed, and bundled", () => {
  assertBody(parserSource, "parse_source_located_with_binder_authority", [
    "lex_with_offsets(source)",
    "binder_capture_context(starts, ends)",
    "parse_program_located_with_context_impl(tokens, starts, source, Some(context))",
    "binder_capture_is_eligible(context)",
    "validate_program_binder_rows(program, rows, source)",
  ], ["tokens: Array[Token]", "context: Option[ParserBinderContext]"]);
  assertBody(binderContextSource, "binder_capture_source", [
    "Array::get(starts, first_token)",
    "Array::get(ends, last_token)",
  ]);
  assertBody(binderContextSource, "binder_capture_swap_segments", [
    "binder_capture_take_from(context, start)",
    "Array::slice(all, cut, Array::length(all))",
    "Array::slice(all, 0, cut)",
  ]);
  assertBody(binderContextSource, "binder_capture_discard_segment", [
    "start < 0 || end < start || end > length",
    "Array::set(c.rows, i - removed, Array::get(c.rows, i))",
    "Array::truncate(c.rows, length - removed)",
    "None => ()",
  ], ["Array::slice", "SourceToken", "Synthetic"]);
  assertBody(parserSource, "parse_source_located_with_binder_authority", [
    "binder_capture_context(starts, ends)",
  ]);
  assertBody(binderAuthoritySource, "validate_program_binder_rows", [
    "next == Array::length(rows)",
    "_ => (false, next)",
  ]);
  assert.match(parserContract, /opaque type LocatedProgramBinderAuthority/);
  assert.match(parserContract, /fn parse_source_located_with_binder_authority\(source: String\)/);
  assert.match(compilerManifest, /parser_binder_authority\.vibe/);
  assert.equal((parserSource.match(/lex_with_offsets\(source\)/g) ?? []).length, 1, "only source-owning authority entry lexes source with exact offsets");
});

test("malformed binder context failures use guarded poison and fixed append bounds", () => {
  assertBody(binderContextSource, "binder_capture_poison", [
    "Array::length(context.eligible) == 1",
    "Array::set(context.eligible, 0, false)",
  ]);
  assertBody(binderContextSource, "binder_capture_shape_is_valid", [
    "Array::length(context.eligible) != 1",
    "Array::length(context.ends_stack) != depth",
    "Array::length(context.bases) != depth",
    "Array::length(starts) != Array::length(ends)",
  ]);
  for (const helper of [
    "binder_capture_source",
    "binder_capture_insert_synthetic_at",
    "binder_capture_swap_segments",
    "binder_capture_discard_segment",
    "binder_capture_discard_from",
    "binder_capture_take_from",
    "binder_capture_rename_first_synthetic",
    "binder_capture_push_fragment",
    "binder_capture_pop_fragment",
    "binder_capture_mark_ineligible",
  ]) {
    assertBody(binderContextSource, helper, ["binder_capture_poison(c)"], ["Array::set(c.eligible"]);
  }
  assertBody(binderContextSource, "binder_capture_append", [
    "let input_length = Array::length(rows)",
    "while i < input_length",
  ], ["for row in rows"]);
});

test("new source EFn slots capture exact header tokens before params and bodies", () => {
  const generic = functionBody(primarySource, "parse_generic_fn_type_params_with_binder_context");
  assert.ok(generic.indexOf("binder_capture_source(context, name, p, p)") < generic.indexOf("parse_generic_type_param_bound_names(tokens, p + 1)"));
  const dispatch = functionBody(dispatchSource, "parse_impl_dispatch_with_binder_context");
  assert.ok(dispatch.indexOf("binder_capture_source(context, gname, br, br)") < dispatch.indexOf("parse_recur(tokens, arrow, 0, context)"));
  assert.ok(dispatch.indexOf("binder_capture_source(context, rname, pos, pos)") < dispatch.lastIndexOf("parse_recur(tokens, br, 20, context)"));
  assertBody(exprSource, "apply_generic_fn_annotation", ["binder_capture_discard_segment(context, retained_value_header_mark, retained_value_header_mark + retained_value_header_count)"]);
  assertBody(exprSource, "apply_value_bracket_type_params", [
    "binder_capture_discard_segment(context, header_mark, header_mark + count)",
    "header_mark, Array::length(existing_tp)",
  ]);
  assertBody(dispatchSource, "apply_local_let_tp", ["binder_capture_discard_segment(context, value_mark, value_mark + Array::length(existing_tps))"]);
});

test("call shorthand captures its parameter before parsing its body", () => {
  const body = functionBody(coreSource, "parse_call_arg");
  const capture = body.indexOf("binder_capture_source(context, name, pos, pos)");
  const parseBody = body.indexOf("parse_recur(tokens, pos + 2, 0, context)");
  assert.notEqual(capture, -1, "parse_call_arg: missing shorthand source capture");
  assert.notEqual(parseBody, -1, "parse_call_arg: missing shorthand body parse");
  assert.ok(capture < parseBody, "parse_call_arg: shorthand binder must precede body rows");
});

test("parser binder context crosses every immediate binder-bearing lowering and remap seam", () => {
  for (const helper of [
    "apply_fn_annotation_params",
    "apply_generic_fn_annotation",
    "apply_generic_let_annotation",
    "apply_value_bracket_type_params",
    "record_destr_marker",
    "top_level_pattern_let",
    "emit_top_level_pat_bindings",
    "emit_top_level_pat_projection",
    "parse_fn_wasm_body",
  ]) {
    assertContextual(exprSource, helper, []);
  }
  assertContextual(exprSource, "expand_top_level_pattern_lets_with_binder_context", [
    "emit_top_level_pat_bindings(out, pat, tmp, context)",
  ], ["emit_top_level_pat_bindings(out, pat, tmp)"]);
  assertNoneWrapper(exprSource, "expand_top_level_pattern_lets", "expand_top_level_pattern_lets_with_binder_context(stmts, None)");
  assertContextual(exprSource, "lower_fn_decl_stmt_with_binder_context", [
    'ELet("result", body, exit_expr, -1)',
    "SLet(exported, true, name, None, EFn",
  ]);
  assertNoneWrapper(exprSource, "lower_fn_decl_stmt", "lower_fn_decl_stmt_with_binder_context(stmt, None)");
  assertBody(exprSource, "lower_fn_decl_stmts", ["lower_fn_decl_stmt_with_binder_context(s, None)"], ["lower_fn_decl_stmt(s)"]);

  assertContextual(parserSource, "parse_stmt_with_binder_context", [
    "lower_fn_decl_stmt_with_binder_context(stmt, context)",
  ], ["lower_fn_decl_stmt(stmt)"]);
  assertContextual(parserSource, "parse_program_located_with_context_impl", [
    "expand_top_level_pattern_lets_with_binder_context(ArrayBuilder::freeze(b), context)",
    "parse_impl_methods(tokens, hp, simpl, context)",
  ], ["expand_top_level_pattern_lets(ArrayBuilder::freeze(b))"]);

  assertContextual(coreSource, "wrap_placeholder_arg", ['String::concat("__ph", __to_string(pc))']);
  assertContextual(coreSource, "desugar_placeholder_args", ["wrap_placeholder_arg(arg, context)"], ["wrap_placeholder_arg(arg)"]);
  assertContextual(coreSource, "parse_postfix", ["desugar_placeholder_args(args, context)"], ["desugar_placeholder_args(args)"]);

  for (const helper of ["map_expr_offsets", "map_exprs", "map_named_exprs", "map_arm_exprs"]) {
    assertContextual(primarySource, helper, []);
  }
  assertContextual(baseSource, "parse_bounded_type_params_with_binder_context", ["parse_trait_bound_names(tokens, p + 1)"], ["parse_trait_bound_names(tokens, p + 1, context)"]);
  assertBody(baseSource, "parse_trait_bound_names", [], ["context"]);
  assertContextual(dispatchSource, "dispatch_type_params_with_binder_context", ["dispatch_tp_bound_names(tokens, p + 1)"], ["dispatch_tp_bound_names(tokens, p + 1, context)"]);
  assertBody(dispatchSource, "dispatch_tp_bound_names", [], ["context"]);
  assertContextual(primarySource, "parse_generic_fn_type_params_with_binder_context", ["parse_generic_type_param_bound_names(tokens, p + 1)"], ["parse_generic_type_param_bound_names(tokens, p + 1, context)"]);
  assertBody(primarySource, "parse_generic_type_param_bound_names", [], ["context"]);
  assertContextual(primarySource, "build_interp_expr", [
    "map_expr_offsets(pe0, (o) -> remap_frag_off(o, outer_starts, fstarts, frag_off), context)",
  ], ["map_expr_offsets(pe0, (o) -> remap_frag_off(o, outer_starts, fstarts, frag_off))"]);
  assertContextual(primarySource, "desugar_loop_body", [
    "desugar_loop_body(val, param_names, context)",
    'String::concat("__lt", __to_string(ci2))',
  ], ["desugar_loop_body(val, param_names)"]);
  assertContextual(primarySource, "parse_loop_primary", [
    "desugar_loop_body(body, pnames, context)",
    'ELetMut("__loop_result"',
  ], ["desugar_loop_body(body, pnames)"]);

  for (const helper of [
    "ascribe_wrap",
    "distribute_local_fn_ann",
    "apply_local_let_tp",
    "desugar_guarded",
    "qualify_handle_arm_pattern",
    "apply_struct_destr",
    "apply_record_destr",
    "apply_block_step",
    "fold_block_steps",
    "push_pattern_let_step",
  ]) {
    assertContextual(dispatchSource, helper, []);
  }
  assertContextual(dispatchSource, "parse_handle_arm", ["qualify_handle_arm_pattern(effect_name, pat, context)"], ["qualify_handle_arm_pattern(effect_name, pat)"]);
  assertContextual(dispatchSource, "parse_impl_block", [
    "fold_block_steps(ArrayBuilder::freeze(steps), context)",
    "ascribe_wrap(val, the_type, value_mark, context)",
    "push_pattern_let_step(tokens, steps, pat, val, next_pos, context)",
  ], [
    "fold_block_steps(ArrayBuilder::freeze(steps))",
    "ascribe_wrap(val, the_type)",
    "push_pattern_let_step(tokens, steps, pat, val, next_pos)",
  ]);
  assertContextual(dispatchSource, "parse_impl_dispatch_with_binder_context", [
    'desugar_guarded(arms3, 0, EIdent("__mg", 0 - 1), context)',
    "parse_recur(tokens, arrow, 0, context)",
    "parse_recur(tokens, br, 20, context)",
    "(gname, None)",
    "(rname, None)",
  ], [
    'desugar_guarded(arms3, 0, EIdent("__mg", 0 - 1))',
  ]);
});
