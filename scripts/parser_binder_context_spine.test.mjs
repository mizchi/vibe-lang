import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const baseSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_base.vibe", import.meta.url)), "utf8");
const exprSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr.vibe", import.meta.url)), "utf8");
const coreSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_core.vibe", import.meta.url)), "utf8");
const dispatchSource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_dispatch.vibe", import.meta.url)), "utf8");
const primarySource = readFileSync(fileURLToPath(new URL("../lib/@vibe/parser/parser_expr_primary.vibe", import.meta.url)), "utf8");
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
  // High-level entry has no caller context parameter and mints fresh plumbing.
  assertBody(parserSource, "parse_program_located_with_binder_context", ["parse_program_located_with_context_impl(tokens, starts, source, Some(ParserBinderContext::{"], ["context: Option[ParserBinderContext]"]);
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
    "ascribe_wrap(val, the_type, context)",
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
