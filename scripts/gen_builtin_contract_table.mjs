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
  const case_re =
    /((?:"[^"]+"\s*\|\s*)*"[^"]+")(?:\s+if[\s\S]*?)?\s*=>/gms;
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

const extract_all_strings = (text) => {
  const out = new Set();
  for (const m of text.matchAll(/"([^"]+)"/g)) {
    out.add(m[1]);
  }
  return out;
};

const extract_builtin_effects = (text) => {
  const out = new Map();
  const effect_re =
    /((?:"[^"]+"\s*\|\s*)*"[^"]+")\s*=>\s*\[@core\.EffectAtom::Const\("([^"]+)"\)\]/gms;
  for (const m of text.matchAll(effect_re)) {
    for (const q of m[1].matchAll(/"([^"]+)"/g)) {
      out.set(q[1], m[2]);
    }
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
  "path": "(String) -> Path",
  "addr": "(String literal) -> T  // address lookup",
  "sh": "(String) -> Unit",
  "sh_lines": "(String) -> Array[String]",
  "sleep": "(Int) -> Unit",
  "Stdout::write_char": "(Int) -> Unit",
  "Stdout::write_stream": "(String) -> Unit",
  "Stdin::read_char": "() -> Int",
  "Stdin::read_stream": "(Int) -> String",
  "String::from_char_code": "(Int) -> String",
  "String::from_char_codes": "(Array[Int]) -> String",
  "ArrayBuilder::new": "() -> ArrayBuilder[T]",
  "ArrayBuilder::push": "(ArrayBuilder[T], T) -> Unit",
  "ArrayBuilder::freeze": "(ArrayBuilder[T]) -> Array[T]",
  "MapBuilder::new": "() -> MapBuilder[K, V]",
  "MapBuilder::set": "(MapBuilder[K, V], K, V) -> Unit",
  "MapBuilder::freeze": "(MapBuilder[K, V]) -> Map[K, V]",
  "Array::length": "(Array[T]) -> Int",
  "Array::get": "(Array[T], Int) -> T",
  "Map::get": "(Map[K, V], K) -> V",
  "Map::set": "(Map[K, V], K, V) -> Map[K, V]",
  "String::length": "(String) -> Int",
  "String::char_code_at": "(String, Int) -> Int",
  "String::substring": "(String, Int, Int) -> String",
  "String::concat": "(String, String) -> String",
  "String::equals": "(String, String) -> Bool",
  "String::split": "(String, String) -> Array[String]",
  "String::index_of": "(String, String) -> Int",
  "String::contains": "(String, String) -> Bool",
  "String::trim": "(String) -> String",
  "__add": "(Num, Num) -> Num",
  "__sub": "(Num, Num) -> Num",
  "__mul": "(Num, Num) -> Num",
  "__div": "(Num, Num) -> Num",
  "__mod": "(Num, Num) -> Num",
  "__lshift": "(Int, Int) -> Int",
  "__rshift": "(Int, Int) -> Int",
  "__bit_and": "(Int, Int) -> Int",
  "__bit_or": "(Int, Int) -> Int",
  "__bit_xor": "(Int, Int) -> Int",
  "i32_shr_u": "(Int, Int) -> Int",
  "__index": "(Array[T], Int) -> T | (Map[K, V], K) -> V",
  "__eq": "(Eq, Eq) -> Bool",
  "__lt": "(Ord, Ord) -> Bool",
  "__neg": "(Num) -> Num",
  "__assert": "(Bool) -> Unit",
  "record_set": "(Record{...}, String, V) -> Record{...}",
  "Map::keys": "(Map[K, V]) -> Array[K]",
  "Map::values": "(Map[K, V]) -> Array[V]",
  "Map::has_key": "(Map[K, V], K) -> Bool",
  "Array::slice": "(Array[T], Int, Int) -> Array[T]",
  "Int::to_float": "(Int) -> Float",
  "f32_convert_i32_s": "(Int) -> Float",
  "Int::to_double": "(Int) -> Double",
  "f64_convert_i32_s": "(Int) -> Double",
  "Float::to_int": "(Float) -> Int",
  "i32_trunc_f32_s": "(Float) -> Int",
  "Float::to_double": "(Float) -> Double",
  "f64_promote_f32": "(Float) -> Double",
  "Double::to_int": "(Double) -> Int",
  "i32_trunc_f64_s": "(Double) -> Int",
  "Double::to_float": "(Double) -> Float",
  "f32_demote_f64": "(Double) -> Float",
  "f32_neg": "(Float) -> Float",
  "f64_neg": "(Double) -> Double",
  "i32_load": "(Int, Int) -> Int",
  "i32_load8_u": "(Int, Int) -> Int",
  "i32_store": "(Int, Int, Int) -> Unit",
  "i32_store8": "(Int, Int, Int) -> Unit",
  "f32_load": "(Int, Int) -> Float",
  "f64_load": "(Int, Int) -> Double",
  "f32_store": "(Int, Int, Float) -> Unit",
  "f64_store": "(Int, Int, Double) -> Unit",
  "Threads::probe_wat": "() -> String",
  "Threads::runtime_hints":
    "() -> {wasm_flags: Array[String], wasi_flags: Array[String], wasm_env: String, wasi_env: String}",
  "Threads::channel_new": "(Int) -> ThreadChannel[T]",
  "Threads::send": "(ThreadChannel[T], T) -> Bool",
  "Threads::recv": "(ThreadChannel[T]) -> T",
  "Threads::spawn": "(String, ThreadChannel[T]) -> ThreadTask[Int]",
  "Threads::wait": "(ThreadTask[Int]) -> Int",
  "__to_string": "(Any) -> String",
};

const checker_builtin_sources = [
  read_text("src/checker/typecheck_call_builtin_handler_core_io.mbt"),
  read_text("src/checker/typecheck_call_builtin_handler_collection_numeric.mbt"),
  read_text("src/checker/typecheck_call_builtin_handler_runtime_memory.mbt"),
  read_text("src/checker/typecheck_call_builtin_handler_json_and_fallback.mbt"),
];
const checker_builtin_registry = read_text("src/checker/builtin_declared_names.mbt");
const checker_effects = read_text("src/checker/typecheck_effects_set.mbt");
const codegen_builtin_registry = read_text(
  "src/codegen/wasm_codegen_builtin_names.mbt",
);
const codegen_builtin_sources = [
  read_text("src/codegen/wasm_codegen_builtin_collection.mbt"),
  read_text("src/codegen/wasm_codegen_builtin_io.mbt"),
  read_text("src/codegen/wasm_codegen_builtin_misc.mbt"),
  read_text("src/codegen/wasm_codegen_builtin_numeric.mbt"),
  read_text("src/codegen/wasm_codegen_builtin_string.mbt"),
  read_text("src/codegen/wasm_codegen_call.mbt"),
];

const checker_builtin_effects = checker_effects.slice(
  checker_effects.indexOf("fn builtin_effects("),
);
const codegen_registered_names = extract_all_strings(
  slice_between(
    codegen_builtin_registry,
    "pub fn codegen_registered_builtin_names() -> Array[String] {",
    "pub fn codegen_runtime_fallback_builtin_names() -> Array[String] {",
  ),
);
const codegen_runtime_fallback_names = extract_all_strings(
  codegen_builtin_registry.slice(
    codegen_builtin_registry.indexOf(
      "pub fn codegen_runtime_fallback_builtin_names() -> Array[String] {",
    ),
  ),
);
const effects = extract_builtin_effects(checker_builtin_effects);
const checker_declared = union(
  extract_all_strings(checker_builtin_registry),
  ...checker_builtin_sources.map((src) => extract_case_names(src)),
);
const do_required = union(
  ...checker_builtin_sources.map((src) => extract_do_required(src)),
);
const compiled_supported = union(
  codegen_registered_names,
  ...codegen_builtin_sources.map((src) => extract_case_names(src)),
  ...codegen_builtin_sources.map((src) => extract_name_eq(src)),
);

const signature_names = Object.keys(signatures).sort();
const unknown_signature_names = signature_names.filter(
  (name) =>
    !checker_declared.has(name) &&
    !compiled_supported.has(name) &&
    !codegen_runtime_fallback_names.has(name),
);

if (unknown_signature_names.length > 0) {
  throw new Error(
    "Signature table includes unknown builtin names: " +
      unknown_signature_names.join(", "),
  );
}

const markdown_escape = (s) => s.replaceAll("|", "\\|");

const rows = signature_names.map((name) => {
  const effect = effects.get(name);
  const effect_text = effect
    ? `{${effect}}`
    : do_required.has(name)
      ? "- (do required)"
      : "-";
  const compiled = compiled_supported.has(name) ? "yes" : "no";
  const component = compiled_supported.has(name) ? "yes" : "no";
  return `| \`${name}\` | \`${markdown_escape(signatures[name])}\` | \`${markdown_escape(effect_text)}\` | ${compiled} | ${component} |`;
});

const out = [
  "# Builtin Contract Table (Generated)",
  "",
  "Generated by `node scripts/gen_builtin_contract_table.mjs`.",
  "",
  "Sources:",
  "- `src/checker/typecheck_call_builtin_handler_*.mbt`, `src/checker/typecheck_effects_set.mbt`",
  "- `src/codegen/wasm_codegen_builtin_*.mbt`, `src/codegen/wasm_codegen_call.mbt`",
  "- `src/codegen/wasm_codegen_builtin_names.mbt`",
  "",
  "Legend:",
  "- `required effects` is the effect-set contract (`with {...}` requirement).",
  "- `- (do required)` means no effect-set requirement, but current checker",
  "  requires an effect-allowed context (`do { ... }` or effectful function body).",
  "- `compiled` tracks the current public execution surface backed by WASM codegen.",
  "- builtins listed as runtime fallbacks in WASM codegen are treated as unsupported here.",
  "- `component` currently shares builtin codegen support with `compiled`.",
  "",
  "| name | signature | required effects | compiled | component |",
  "| --- | --- | --- | --- | --- |",
  ...rows,
  "",
].join("\n");

const out_path = path.join(repo_root, "docs/builtin_contract_table.generated.md");
fs.writeFileSync(out_path, out, "utf8");
console.log(
  `wrote ${path.relative(repo_root, out_path)} (${signature_names.length} entries)`,
);
