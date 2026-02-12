#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const script_dir = path.dirname(fileURLToPath(import.meta.url));
const repo_root = path.resolve(script_dir, "..");

const read_text = (rel) => fs.readFileSync(path.join(repo_root, rel), "utf8");

const slice_between = (text, start_marker, end_marker) => {
  const start = text.indexOf(start_marker);
  if (start < 0) {
    throw new Error(`start marker not found: ${start_marker}`);
  }
  const end = text.indexOf(end_marker, start);
  if (end < 0) {
    throw new Error(`end marker not found: ${end_marker}`);
  }
  return text.slice(start, end);
};

const extract_case_names = (text) => {
  const out = new Set();
  const case_re = /((?:"[^"]+"\s*\|\s*)*"[^"]+")\s*=>/gms;
  for (const m of text.matchAll(case_re)) {
    for (const q of m[1].matchAll(/"([^"]+)"/g)) {
      out.add(q[1]);
    }
  }
  return out;
};

const extract_name_eq = (text) => {
  const out = new Set();
  const eq_re = /name\s*==\s*"([^"]+)"/g;
  for (const m of text.matchAll(eq_re)) {
    out.add(m[1]);
  }
  return out;
};

const extract_builtin_effects = (text) => {
  const out = new Map();
  const effect_re =
    /"([^"]+)"\s*=>\s*\[@core\.EffectAtom::Const\("([^"]+)"\)\]/g;
  for (const m of text.matchAll(effect_re)) {
    out.set(m[1], m[2]);
  }
  return out;
};

const extract_do_required = (text) => {
  const out = new Set();
  const re = /EffectNotAllowed\(\s*name="([^"]+)"/g;
  for (const m of text.matchAll(re)) {
    out.add(m[1]);
  }
  return out;
};

const union = (...sets) => {
  const out = new Set();
  for (const set of sets) {
    for (const item of set) {
      out.add(item);
    }
  }
  return out;
};

const signatures = {
  path: "(String) -> Path",
  addr: "(String literal) -> T  // address lookup",
  sh: "(String) -> Unit",
  sh_lines: "(String) -> Array[String]",
  sleep: "(Int) -> Unit",
  threads_probe_wat: "() -> String",
  threads_runtime_hints:
    "() -> {wasm_flags: Array[String], wasi_flags: Array[String], wasm_env: String, wasi_env: String}",
  threads_channel_new: "(Int) -> Int",
  threads_send: "(Int, String) -> Bool",
  threads_recv: "(Int) -> String",
  threads_spawn: "(String, Int) -> Int",
  threads_wait: "(Int) -> Int",
  stdout_write_char: "(Int) -> Unit",
  stdout_write_stream: "(String) -> Unit",
  stdin_read_char: "() -> Int",
  stdin_read_stream: "(Int) -> String",
  string_from_char_code: "(Int) -> String",
  array_builder: "() -> ArrayBuilder[T]",
  array_builder_push: "(ArrayBuilder[T], T) -> Unit",
  array_builder_freeze: "(ArrayBuilder[T]) -> Array[T]",
  map_builder: "() -> MapBuilder[T]",
  map_builder_set: "(MapBuilder[T], String, T) -> Unit",
  map_builder_freeze: "(MapBuilder[T]) -> Map[T]",
  array_length: "(Array[T]) -> Int",
  array_get: "(Array[T], Int) -> T",
  map_get: "(Map[T], String) -> T",
  string_length: "(String) -> Int",
  string_char_code_at: "(String, Int) -> Int",
  string_substring: "(String, Int, Int) -> String",
  string_concat: "(String, String) -> String",
  string_equals: "(String, String) -> Bool",
  string_split: "(String, String) -> Array[String]",
  string_index_of: "(String, String) -> Int",
  string_contains: "(String, String) -> Bool",
  string_trim: "(String) -> String",
  __add: "(Num, Num) -> Num",
  __sub: "(Num, Num) -> Num",
  __mul: "(Num, Num) -> Num",
  __div: "(Num, Num) -> Num",
  __mod: "(Num, Num) -> Num",
  __lshift: "(Int, Int) -> Int",
  __rshift: "(Int, Int) -> Int",
  __bit_and: "(Int, Int) -> Int",
  __bit_or: "(Int, Int) -> Int",
  __bit_xor: "(Int, Int) -> Int",
  i32_shr_u: "(Int, Int) -> Int",
  __index: "(Array[T], Int) -> T | (Map[T], String) -> T",
  __eq: "(Eq, Eq) -> Bool",
  __lt: "(Ord, Ord) -> Bool",
  __neg: "(Num) -> Num",
  __assert: "(Bool) -> Unit",
  record_set: "(Record{...}, String, V) -> Record{...}",
  map_keys: "(Map[T]) -> Array[String]",
  map_values: "(Map[T]) -> Array[T]",
  map_has_key: "(Map[T], String) -> Bool",
  array_slice: "(Array[T], Int, Int) -> Array[T]",
  int_to_float: "(Int) -> Float",
  f32_convert_i32_s: "(Int) -> Float",
  int_to_double: "(Int) -> Double",
  f64_convert_i32_s: "(Int) -> Double",
  float_to_int: "(Float) -> Int",
  i32_trunc_f32_s: "(Float) -> Int",
  float_to_double: "(Float) -> Double",
  f64_promote_f32: "(Float) -> Double",
  double_to_int: "(Double) -> Int",
  i32_trunc_f64_s: "(Double) -> Int",
  double_to_float: "(Double) -> Float",
  f32_demote_f64: "(Double) -> Float",
  f32_neg: "(Float) -> Float",
  f64_neg: "(Double) -> Double",
  i32_load: "(Int, Int) -> Int",
  i32_load8_u: "(Int, Int) -> Int",
  i32_store: "(Int, Int, Int) -> Unit",
  i32_store8: "(Int, Int, Int) -> Unit",
  f32_load: "(Int, Int) -> Float",
  f64_load: "(Int, Int) -> Double",
  f32_store: "(Int, Int, Float) -> Unit",
  f64_store: "(Int, Int, Double) -> Unit",
  __to_string: "(Any) -> String",
};

const checker = read_text("src/checker/typecheck.mbt");
const eval_src = read_text("src/runtime/eval.mbt");
const eval_builtins_src = read_text("src/runtime/eval_builtins.mbt");
const wasm_codegen = read_text("src/codegen/wasm_codegen.mbt");

const checker_type_call = slice_between(
  checker,
  "fn type_call(",
  "fn try_field_access(",
);
const checker_builtin_effects = slice_between(
  checker,
  "fn builtin_effects(",
  "fn effect_scope_extend(",
);
const eval_is_pure = slice_between(
  eval_builtins_src,
  "fn is_pure_builtin(",
  "fn eval_pure_builtin(",
);
const eval_call = slice_between(
  eval_src,
  "fn eval_call(",
  "fn ctor_value_from_args(",
);
const wasm_compile_expr = slice_between(
  wasm_codegen,
  "fn compile_expr(",
  "fn extract_positional_exprs(",
);

const checker_builtins = [...extract_case_names(checker_type_call)].sort();
const effects = extract_builtin_effects(checker_builtin_effects);
const do_required = extract_do_required(checker_type_call);

const interpreter_supported = union(
  extract_name_eq(eval_is_pure),
  extract_case_names(eval_call),
);
const wasm_supported = union(
  extract_name_eq(wasm_compile_expr),
  extract_case_names(wasm_compile_expr),
);

const missing_signatures = checker_builtins.filter((name) => !signatures[name]);
if (missing_signatures.length > 0) {
  throw new Error(
    "Missing signature entries for: " + missing_signatures.join(", "),
  );
}

const markdown_escape = (s) => s.replaceAll("|", "\\|");

const rows = checker_builtins.map((name) => {
  const effect = effects.get(name);
  const effect_text = effect
    ? `{${effect}}`
    : do_required.has(name)
      ? "- (do required)"
      : "-";
  const interp = interpreter_supported.has(name) ? "yes" : "no";
  const wasm = wasm_supported.has(name) ? "yes" : "no";
  const component = wasm_supported.has(name) ? "yes" : "no";
  return `| \`${name}\` | \`${markdown_escape(signatures[name])}\` | \`${markdown_escape(effect_text)}\` | ${interp} | ${wasm} | ${component} |`;
});

const out = [
  "# Builtin Contract Table (Generated)",
  "",
  "Generated by `node scripts/gen_builtin_contract_table.mjs`.",
  "",
  "Sources:",
  "- `src/checker/typecheck.mbt` (`type_call`, `builtin_effects`)",
  "- `src/runtime/eval.mbt` (`is_pure_builtin`, `eval_call`)",
  "- `src/codegen/wasm_codegen.mbt` (`compile_expr`)",
  "",
  "Legend:",
  "- `required effects` is the effect-set contract (`with {...}` requirement).",
  "- `- (do required)` means no effect-set requirement, but current checker",
  "  requires an effect-allowed context (`do { ... }` or effectful function body).",
  "- `component` currently shares builtin codegen support with `wasm`.",
  "",
  "| name | signature | required effects | interpreter | wasm | component |",
  "| --- | --- | --- | --- | --- | --- |",
  ...rows,
  "",
].join("\n");

const out_path = path.join(repo_root, "docs/builtin_contract_table.generated.md");
fs.writeFileSync(out_path, out, "utf8");
console.log(
  `wrote ${path.relative(repo_root, out_path)} (${checker_builtins.length} entries)`,
);
