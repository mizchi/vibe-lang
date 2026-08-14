import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const exprSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr.vibe", import.meta.url)), "utf8");
const parserSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser.vibe", import.meta.url)), "utf8");

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
  assertNoneWrapper(exprSource, "parse_fn_signature", "parse_fn_signature_with_binder_context(tokens, pos, None)");
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
    "parse_fn_signature_with_binder_context(tokens, pos, context)",
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
    "parse_import_items(tokens, br, context)",
  ], [
    "parse_let_stmt(tokens,",
    "parse_fn_stmt(tokens,",
    "parse_enum_stmt(tokens,",
    "parse_suberror_stmt(tokens,",
    "parse_effect_stmt(tokens,",
    "parse_type_alias_stmt(tokens,",
    "parse_trait_stmt(tokens,",
  ]);
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
    "TStruct => parse_toplevel_struct_stmt(tokens, pos + 1, false, context)",
    '"effectset" => parse_effectset_stmt(tokens, pos + 1, false, context)',
    '"resource" => parse_resource_stmt(tokens, pos + 1, context)',
    '"extern" => parse_extern_let_stmt(tokens, pos + 1, context)',
  ], [
    "parse_let_stmt(tokens,",
    "parse_export_stmt(tokens, starts, pos + 1)",
    "parse_import_stmt(tokens, pos + 1)",
    "parse_test_stmt(tokens, starts, pos + 1)",
    "parse_fn_stmt(tokens,",
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
  assert.ok(parserSource.includes("parse_impl_methods(tokens, hp_d, simpl_d, None)"), "cfg-disabled ordinary impl path must pass None");
  assert.ok(parserSource.includes("parse_impl_methods(tokens, hp, simpl, None)"), "ordinary impl path must pass None");

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
  // High-level entry has no caller context parameter and mints fresh plumbing.
  assertBody(parserSource, "parse_program_located_with_binder_context", ["parse_program_located_with_context_impl(tokens, starts, source, Some(ParserBinderContext::{"], ["context: Option[ParserBinderContext]"]);
});
