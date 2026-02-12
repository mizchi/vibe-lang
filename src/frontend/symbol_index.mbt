///|
/// Shared symbol/type/signature index for IDE-like queries and LSIF output.
pub enum SymbolKind {
  FnSym
  ValueSym
  TypeAliasSym
  EnumSym
  StructSym
  TraitSym
  CtorSym
  ImplSym
} derive(Show, Eq)

///|
pub struct SymbolEntry {
  name : String
  kind : SymbolKind
  signature : String
  path : String
  span : @core.Span
} derive(Show, Eq)

///|
pub struct SymbolIndex {
  entries : Array[SymbolEntry]
  name_index : Map[String, Int]
  name_dup_index : Map[String, Array[Int]]
  vibe_query_index : Map[String, Array[Int]]
} derive(Show, Eq)

///|
pub fn symbol_kind_name(kind : SymbolKind) -> String {
  match kind {
    SymbolKind::FnSym => "function"
    SymbolKind::ValueSym => "value"
    SymbolKind::TypeAliasSym => "type"
    SymbolKind::EnumSym => "enum"
    SymbolKind::StructSym => "struct"
    SymbolKind::TraitSym => "trait"
    SymbolKind::CtorSym => "constructor"
    SymbolKind::ImplSym => "impl"
  }
}

///|
fn join_with(parts : Array[String], sep : String) -> String {
  if parts.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  for i in 0..<parts.length() {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(parts[i])
  }
  buf.to_string()
}

///|
fn render_effect_atom(atom : @core.EffectAtom) -> String {
  match atom {
    @core.EffectAtom::Const(name) => name
    @core.EffectAtom::Var(name) => "?" + name
  }
}

///|
fn render_param_type(param : @core.FuncParam) -> String {
  let head = match param.label {
    @core.ParamLabel::Positional => param.name + ": " + render_type(param.ty)
    @core.ParamLabel::Required => param.name + "~: " + render_type(param.ty)
    @core.ParamLabel::Optional => param.name + "?: " + render_type(param.ty)
  }
  if param.bounds.length() == 0 {
    head
  } else {
    head + " : " + join_with(param.bounds, " + ")
  }
}

///|
fn sorted_map_keys(map : Map[String, @core.Type]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn render_type(ty : @core.Type) -> String {
  match ty {
    @core.Type::Int => "Int"
    @core.Type::Float => "Float"
    @core.Type::Double => "Double"
    @core.Type::Bool => "Bool"
    @core.Type::String => "String"
    @core.Type::Path => "Path"
    @core.Type::Unit => "Unit"
    @core.Type::Never => "Never"
    @core.Type::Tuple(items) =>
      "(" + join_with(items.map(fn(x) { render_type(x) }), ", ") + ")"
    @core.Type::Record(fields) => {
      let parts : Array[String] = []
      let keys = sorted_map_keys(fields)
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => parts.push(key + ": " + render_type(field_ty))
          None => ()
        }
      }
      "{ " + join_with(parts, "; ") + " }"
    }
    @core.Type::Array(item) => "Array[" + render_type(item) + "]"
    @core.Type::Map(item) => "Map[" + render_type(item) + "]"
    @core.Type::ArrayBuilder(item) => "ArrayBuilder[" + render_type(item) + "]"
    @core.Type::MapBuilder(item) => "MapBuilder[" + render_type(item) + "]"
    @core.Type::Variant(fields) => {
      let parts : Array[String] = []
      let keys = sorted_map_keys(fields)
      for key in keys {
        match fields.get(key) {
          Some(field_ty) => parts.push(key + ": " + render_type(field_ty))
          None => ()
        }
      }
      "Variant{ " + join_with(parts, "; ") + " }"
    }
    @core.Type::Named(name~, args~) =>
      if args.length() == 0 {
        name
      } else {
        name + "[" + join_with(args.map(fn(x) { render_type(x) }), ", ") + "]"
      }
    @core.Type::Param(name) => name
    @core.Type::Var(id) => "'t" + id.to_string()
    @core.Type::Func(params~, ret~, effects~) => {
      let params_repr = join_with(
        params.map(fn(p) { render_param_type(p) }),
        ", ",
      )
      let effects_repr = if effects.length() == 0 {
        ""
      } else {
        " with {" +
        join_with(effects.map(fn(e) { render_effect_atom(e) }), ", ") +
        "}"
      }
      "(" + params_repr + ") -> " + render_type(ret) + effects_repr
    }
  }
}

///|
fn render_type_params(params : Array[String]) -> String {
  if params.length() == 0 {
    ""
  } else {
    "[" + join_with(params, ", ") + "]"
  }
}

///|
fn render_type_scheme(scheme : @checker.TypeScheme) -> String {
  let binders : Array[String] = []
  for id in scheme.vars {
    let base = "'t" + id.to_string()
    match scheme.trait_bounds.get(id) {
      Some(bounds) =>
        if bounds.length() == 0 {
          binders.push(base)
        } else {
          binders.push(base + ": " + join_with(bounds, " + "))
        }
      None => binders.push(base)
    }
  }
  for effect_var in scheme.effect_vars {
    binders.push("?" + effect_var)
  }
  if binders.length() == 0 {
    render_type(scheme.ty)
  } else {
    "forall[" + join_with(binders, ", ") + "] " + render_type(scheme.ty)
  }
}

///|
fn render_fn_expr_signature(
  params : Array[@core.FuncParam],
  ret : @core.Type?,
  effects : Array[@core.EffectAtom],
) -> String {
  let ret_ty = match ret {
    Some(v) => render_type(v)
    None => "_"
  }
  let params_repr = join_with(params.map(fn(p) { render_param_type(p) }), ", ")
  let effects_repr = if effects.length() == 0 {
    ""
  } else {
    " with {" +
    join_with(effects.map(fn(e) { render_effect_atom(e) }), ", ") +
    "}"
  }
  "(" + params_repr + ") -> " + ret_ty + effects_repr
}

///|
fn signature_for_let(
  name : String,
  expr : @core.Expr,
  types : @checker.TypeEnv,
) -> String {
  match types.get_scheme(name) {
    Some(scheme) => render_type_scheme(scheme)
    None =>
      match expr {
        @core.Expr::Fn(params~, ret~, effects~, ..) =>
          render_fn_expr_signature(params, ret, effects)
        _ => "_"
      }
  }
}

///|
fn push_symbol(
  entries : Array[SymbolEntry],
  name : String,
  kind : SymbolKind,
  signature : String,
  path : String,
  span : @core.Span,
) -> Unit {
  entries.push(SymbolEntry::{ name, kind, signature, path, span })
}

///|
fn ctor_signature(
  enum_name : String,
  enum_params : Array[String],
  ctor : @core.TypeCtor,
) -> String {
  let result_ty = enum_name + render_type_params(enum_params)
  if ctor.args.length() == 0 {
    result_ty
  } else if ctor.args.length() == 1 {
    render_type(ctor.args[0]) + " -> " + result_ty
  } else {
    "(" +
    join_with(ctor.args.map(fn(x) { render_type(x) }), ", ") +
    ") -> " +
    result_ty
  }
}

///|
fn si_push_unique_int(values : Array[Int], value : Int) -> Unit {
  for existing in values {
    if existing == value {
      return
    }
  }
  values.push(value)
}

///|
fn si_push_index_id(
  index_map : Map[String, Array[Int]],
  key : String,
  id : Int,
) -> Unit {
  match index_map.get(key) {
    Some(existing) => {
      si_push_unique_int(existing, id)
      index_map[key] = existing
    }
    None => index_map[key] = [id]
  }
}

///|
fn si_collect_entries_by_ids(
  entries : Array[SymbolEntry],
  ids : Array[Int],
) -> Array[SymbolEntry] {
  let out : Array[SymbolEntry] = []
  for id in ids {
    if id >= 0 && id < entries.length() {
      out.push(entries[id])
    }
  }
  out
}

///|
fn si_is_identifier_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_' || c == '?'
}

///|
fn si_signature_tokens(signature : String) -> Array[String] {
  let out : Array[String] = []
  let mut current = ""
  for _, c in signature {
    if c == '+' {
      if current.length() > 0 {
        out.push(current)
        current = ""
      }
      out.push("+")
      continue
    }
    if si_is_identifier_char(c) {
      current = current + c.to_string()
    } else if current.length() > 0 {
      out.push(current)
      current = ""
    }
  }
  if current.length() > 0 {
    out.push(current)
  }
  out
}

///|
fn si_is_bound_atom(token : String) -> Bool {
  if token.length() == 0 {
    return false
  }
  match token.get_char(0) {
    Some(first) => first.is_ascii_uppercase() || first == '?'
    None => false
  }
}

///|
fn si_collect_plus_bound_fragments(
  signature : String,
  out : Array[String],
) -> Unit {
  let tokens = si_signature_tokens(signature)
  let mut i = 0
  while i < tokens.length() {
    if i + 2 >= tokens.length() {
      i += 1
      continue
    }
    if tokens[i + 1] != "+" ||
      not(si_is_bound_atom(tokens[i])) ||
      not(si_is_bound_atom(tokens[i + 2])) {
      i += 1
      continue
    }
    let atoms : Array[String] = [tokens[i]]
    let mut j = i
    while j + 2 < tokens.length() {
      if tokens[j + 1] != "+" || not(si_is_bound_atom(tokens[j + 2])) {
        break
      }
      atoms.push(tokens[j + 2])
      j += 2
    }
    for start in 0..<atoms.length() {
      if start + 1 >= atoms.length() {
        continue
      }
      let mut fragment = atoms[start]
      for end in (start + 1)..<atoms.length() {
        fragment = fragment + " + " + atoms[end]
        out.push(fragment)
      }
    }
    i = j + 1
  }
}

///|
fn si_collect_effect_fragments(signature : String, out : Array[String]) -> Unit {
  let chunks : Array[String] = []
  for part_view in signature.split("with {") {
    chunks.push(part_view.to_string())
  }
  if chunks.length() <= 1 {
    return
  }
  for i in 1..<chunks.length() {
    let tail = chunks[i]
    match tail.find("}") {
      Some(end_pos) => {
        let inner_raw = tail.unsafe_substring(start=0, end=end_pos)
        let inner = inner_raw.trim().to_string()
        if inner.length() == 0 {
          continue
        }
        out.push("with {" + inner + "}")
        for effect_view in inner.split(",") {
          let effect = effect_view.to_string().trim().to_string()
          if effect.length() > 0 {
            out.push("with {" + effect + "}")
          }
        }
      }
      None => ()
    }
  }
}

///|
fn si_collect_vibe_query_fragments(signature : String) -> Array[String] {
  let raw : Array[String] = []
  if signature.contains(" + ") {
    si_collect_plus_bound_fragments(signature, raw)
  }
  if signature.contains("with {") {
    si_collect_effect_fragments(signature, raw)
  }
  let seen : Map[String, Bool] = {}
  let out : Array[String] = []
  for item in raw {
    if item.length() == 0 || seen.contains(item) {
      continue
    }
    seen[item] = true
    out.push(item)
  }
  out
}

///|
fn si_build_name_index(
  entries : Array[SymbolEntry],
) -> (Map[String, Int], Map[String, Array[Int]]) {
  let primary : Map[String, Int] = {}
  let dups : Map[String, Array[Int]] = {}
  for i in 0..<entries.length() {
    let name = entries[i].name
    match primary.get(name) {
      None => primary[name] = i
      Some(first_id) =>
        match dups.get(name) {
          Some(ids) => {
            si_push_unique_int(ids, i)
            dups[name] = ids
          }
          None => dups[name] = [first_id, i]
        }
    }
  }
  (primary, dups)
}

///|
fn si_build_vibe_query_index(
  entries : Array[SymbolEntry],
) -> Map[String, Array[Int]] {
  let out : Map[String, Array[Int]] = {}
  for i in 0..<entries.length() {
    let signature = entries[i].signature
    if not(signature.contains(" + ") || signature.contains("with {")) {
      continue
    }
    for key in si_collect_vibe_query_fragments(signature) {
      si_push_index_id(out, key, i)
    }
  }
  out
}

///|
fn si_build_symbol_index(entries : Array[SymbolEntry]) -> SymbolIndex {
  let (name_index, name_dup_index) = si_build_name_index(entries)
  SymbolIndex::{
    entries,
    name_index,
    name_dup_index,
    vibe_query_index: si_build_vibe_query_index(entries),
  }
}

///|
fn si_should_use_vibe_fast_path(query : String) -> Bool {
  query.has_prefix("with {") || query.contains(" + ")
}

///|
pub fn build_symbol_index_for_module(
  path : String,
  ast : @core.Module,
  types : @checker.TypeEnv,
) -> SymbolIndex {
  let entries : Array[SymbolEntry] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, span~, ..)
      | @core.Stmt::ExportLet(name~, expr~, span~, ..) => {
        let kind = match expr {
          @core.Expr::Fn(..) => SymbolKind::FnSym
          _ => SymbolKind::ValueSym
        }
        push_symbol(
          entries,
          name,
          kind,
          signature_for_let(name, expr, types),
          path,
          span,
        )
      }
      @core.Stmt::LetMut(name~, span~, ..) =>
        push_symbol(entries, name, SymbolKind::ValueSym, "mut", path, span)
      @core.Stmt::TypeAlias(name~, params~, target~, span~)
      | @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        push_symbol(
          entries,
          name,
          SymbolKind::TypeAliasSym,
          "type " +
          name +
          render_type_params(params) +
          " = " +
          render_type(target),
          path,
          span,
        )
      @core.Stmt::EnumDef(name~, params~, ctors~, span~)
      | @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        push_symbol(
          entries,
          name,
          SymbolKind::EnumSym,
          "enum " + name + render_type_params(params),
          path,
          span,
        )
        for ctor in ctors {
          push_symbol(
            entries,
            ctor.name,
            SymbolKind::CtorSym,
            ctor_signature(name, params, ctor),
            path,
            ctor.span,
          )
        }
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~)
      | @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
        let field_parts : Array[String] = []
        for field in fields {
          field_parts.push(field.name + ": " + render_type(field.ty))
        }
        push_symbol(
          entries,
          name,
          SymbolKind::StructSym,
          "struct " +
          name +
          render_type_params(params) +
          " { " +
          join_with(field_parts, "; ") +
          " }",
          path,
          span,
        )
      }
      @core.Stmt::TraitDef(name~, supertraits~, span~, ..) => {
        let suffix = if supertraits.length() == 0 {
          ""
        } else {
          ": " + join_with(supertraits, " + ")
        }
        push_symbol(
          entries,
          name,
          SymbolKind::TraitSym,
          "trait " + name + suffix,
          path,
          span,
        )
      }
      @core.Stmt::TraitImpl(trait_name~, target~, span~, ..) =>
        push_symbol(
          entries,
          trait_name,
          SymbolKind::ImplSym,
          "impl " + trait_name + " for " + render_type(target),
          path,
          span,
        )
      @core.Stmt::Expr(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::Test(..)
      | @core.Stmt::Bench(..)
      | @core.Stmt::Assign(..)
      | @core.Stmt::IndexAssign(..)
      | @core.Stmt::LetPat(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..) => ()
    }
  }
  si_build_symbol_index(entries)
}

///|
pub fn build_symbol_index_from_entries(
  entries : Array[SymbolEntry],
) -> SymbolIndex {
  si_build_symbol_index(entries)
}

///|
pub fn SymbolIndex::find_exact(
  self : SymbolIndex,
  name : String,
) -> Array[SymbolEntry] {
  match self.name_dup_index.get(name) {
    Some(ids) => si_collect_entries_by_ids(self.entries, ids)
    None =>
      match self.name_index.get(name) {
        Some(id) =>
          if id >= 0 && id < self.entries.length() {
            [self.entries[id]]
          } else {
            []
          }
        None => []
      }
  }
}

///|
pub fn SymbolIndex::search(
  self : SymbolIndex,
  query : String,
) -> Array[SymbolEntry] {
  if query.length() == 0 {
    let out : Array[SymbolEntry] = []
    for entry in self.entries {
      out.push(entry)
    }
    return out
  }
  if si_should_use_vibe_fast_path(query) {
    match self.vibe_query_index.get(query) {
      Some(ids) => return si_collect_entries_by_ids(self.entries, ids)
      None => ()
    }
  }
  let out : Array[SymbolEntry] = []
  for entry in self.entries {
    if entry.name.contains(query) || entry.signature.contains(query) {
      out.push(entry)
    }
  }
  out
}
