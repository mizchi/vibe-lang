///| Canonical statement sorting for order-independent normalization.

///| Ensures normalize_module produces the same result regardless of input order.

///|
priv enum CanonicalGroup {
  Use
  TypeDecl
  TraitDecl
  FnDef
  Other
}

///|
/// Sort module statements into canonical order for deterministic hashing.
/// Groups: Use > TypeDecl > TraitDecl > FnDef (topo+alpha) > Other
pub fn canonical_sort_stmts(stmts : Array[Stmt]) -> Array[Stmt] {
  let use_stmts : Array[Stmt] = []
  let type_stmts : Array[Stmt] = []
  let trait_stmts : Array[Stmt] = []
  let fn_stmts : Array[Stmt] = []
  let other_stmts : Array[Stmt] = []
  for stmt in stmts {
    match canonical_group(stmt) {
      CanonicalGroup::Use => use_stmts.push(stmt)
      CanonicalGroup::TypeDecl => type_stmts.push(stmt)
      CanonicalGroup::TraitDecl => trait_stmts.push(stmt)
      CanonicalGroup::FnDef => fn_stmts.push(stmt)
      CanonicalGroup::Other => other_stmts.push(stmt)
    }
  }
  let use_exports : Array[Stmt] = []
  let use_imports : Array[Stmt] = []
  for stmt in use_stmts {
    match stmt {
      Stmt::ReExport(..) => use_exports.push(stmt)
      _ => use_imports.push(stmt)
    }
  }
  use_exports.sort_by(fn(a, b) {
    canonical_string_compare(
      canonical_use_stmt_key(a),
      canonical_use_stmt_key(b),
    )
  })
  use_imports.sort_by(fn(a, b) {
    canonical_string_compare(
      canonical_use_stmt_key(a),
      canonical_use_stmt_key(b),
    )
  })
  let fn_sorted = canonical_sort_fns_topo_alpha(fn_stmts)
  let out : Array[Stmt] = []
  for stmt in use_exports {
    out.push(stmt)
  }
  for stmt in use_imports {
    out.push(stmt)
  }
  for stmt in type_stmts {
    out.push(stmt)
  }
  for stmt in trait_stmts {
    out.push(stmt)
  }
  for stmt in fn_sorted {
    out.push(stmt)
  }
  for stmt in other_stmts {
    out.push(stmt)
  }
  out
}

///|
fn canonical_string_compare(a : String, b : String) -> Int {
  let min_len = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < min_len; i = i + 1 {
    let ac = a[i].to_int()
    let bc = b[i].to_int()
    if ac != bc {
      return ac - bc
    }
  }
  a.length() - b.length()
}

///|
fn canonical_module_ref_key(source : ModuleRef) -> String {
  match source {
    ModuleRef::Path(path~) => "path:" + path
    ModuleRef::Hash(hash~) => "hash:" + hash
    ModuleRef::Version(name~) => "version:" + name
    ModuleRef::Symbol(name~) => "symbol:" + name
    ModuleRef::Alias(name~) => "alias:" + name
    ModuleRef::PinnedPath(path~, hash~) => "pinned:" + path + "#" + hash
  }
}

///|
fn canonical_import_item_key(item : ImportItem) -> String {
  let kind = match item.kind {
    ImportKind::Value => "0"
    ImportKind::Type => "1"
    ImportKind::Trait => "2"
    ImportKind::Module => "3"
    ImportKind::Struct => "4"
    ImportKind::Effect => "5"
    ImportKind::Suberror => "6"
  }
  let local_name = match item.rename {
    Some(name) => name
    None => item.name
  }
  kind + ":" + item.name + ":" + local_name
}

///|
fn canonical_import_spec_key(spec : ImportSpec) -> String {
  let keys : Array[String] = []
  for item in spec.items {
    keys.push(canonical_import_item_key(item))
  }
  keys.sort()
  keys.join(",")
}

///|
fn canonical_use_stmt_key(stmt : Stmt) -> String {
  match stmt {
    Stmt::Import(spec~, source~, ..) =>
      "import:" +
      canonical_module_ref_key(source) +
      ":" +
      canonical_import_spec_key(spec)
    Stmt::ReExport(spec~, source~, ..) =>
      "export:" +
      canonical_module_ref_key(source) +
      ":" +
      canonical_import_spec_key(spec)
    _ => ""
  }
}

///|
fn canonical_group(stmt : Stmt) -> CanonicalGroup {
  match stmt {
    Stmt::Import(..) | Stmt::ReExport(..) | Stmt::AliasDecl(..) =>
      CanonicalGroup::Use
    Stmt::TypeAlias(..)
    | Stmt::ExportTypeAlias(..)
    | Stmt::InternalExportTypeAlias(..)
    | Stmt::EnumDef(..)
    | Stmt::ExportEnumDef(..)
    | Stmt::InternalExportEnumDef(..)
    | Stmt::StructDef(..)
    | Stmt::ExportStructDef(..)
    | Stmt::InternalExportStructDef(..) => CanonicalGroup::TypeDecl
    Stmt::TraitDef(..) | Stmt::InternalTraitDef(..) | Stmt::TraitImpl(..) =>
      CanonicalGroup::TraitDecl
    Stmt::Let(..)
    | Stmt::ExportLet(..)
    | Stmt::InternalExportLet(..)
    | Stmt::LetMut(..)
    | Stmt::ExternLet(..) => CanonicalGroup::FnDef
    Stmt::Assign(..)
    | Stmt::IndexAssign(..)
    | Stmt::LetPat(..)
    | Stmt::LetPatElse(..)
    | Stmt::Expr(..) => CanonicalGroup::FnDef
    Stmt::Test(..) | Stmt::Bench(..) | Stmt::Export(..) => CanonicalGroup::Other
  }
}

///|
fn canonical_def_name(stmt : Stmt) -> String? {
  match stmt {
    Stmt::Let(name~, ..)
    | Stmt::ExportLet(name~, ..)
    | Stmt::InternalExportLet(name~, ..)
    | Stmt::LetMut(name~, ..)
    | Stmt::ExternLet(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn canonical_collect_refs(stmt : Stmt) -> Map[String, Bool] {
  let refs : Map[String, Bool] = {}
  let bound = WalkerScope::new()
  match stmt {
    Stmt::Let(rec~, name~, expr~, ..)
    | Stmt::ExportLet(rec~, name~, expr~, ..)
    | Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
      if rec {
        bound.bindings[name] = true
      }
      walk_expr_refs(expr, bound, refs, canonical_add_ref)
    }
    Stmt::LetMut(expr~, ..) =>
      walk_expr_refs(expr, bound, refs, canonical_add_ref)
    Stmt::ExternLet(..) => ()
    _ => ()
  }
  refs
}

///|
fn canonical_add_ref(
  name : String,
  bound : WalkerScope,
  refs : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  refs[name] = true
}

///|
fn canonical_sort_fns_topo_alpha(stmts : Array[Stmt]) -> Array[Stmt] {
  let defs : Array[(String, Stmt, Map[String, Bool])] = []
  for stmt in stmts {
    match canonical_def_name(stmt) {
      Some(name) => defs.push((name, stmt, canonical_collect_refs(stmt)))
      None => ()
    }
  }
  if defs.length() <= 1 {
    return stmts
  }
  let names : Map[String, Bool] = {}
  for def in defs {
    if names.contains(def.0) {
      return stmts
    }
    names[def.0] = true
  }
  let indegree : Map[String, Int] = {}
  let dependents : Map[String, Map[String, Bool]] = {}
  let stmt_by_name : Map[String, Stmt] = {}
  for def in defs {
    indegree[def.0] = 0
    dependents[def.0] = {}
    stmt_by_name[def.0] = def.1
  }
  for def in defs {
    let deps : Map[String, Bool] = {}
    for ref_name, _ in def.2 {
      if ref_name != def.0 && names.contains(ref_name) {
        deps[ref_name] = true
      }
    }
    indegree[def.0] = deps.length()
    for dep_name, _ in deps {
      match dependents.get(dep_name) {
        Some(existing) => existing[def.0] = true
        None => {
          let next : Map[String, Bool] = {}
          next[def.0] = true
          dependents[dep_name] = next
        }
      }
    }
  }
  // Collect initial ready set and sort in descending order so pop() gives smallest
  let ready : Array[String] = []
  for name, deg in indegree {
    if deg == 0 {
      ready.push(name)
    }
  }
  ready.sort_by(fn(a, b) { canonical_name_compare(b, a) })
  let ordered_names : Array[String] = []
  while ready.length() > 0 {
    let name = match ready.pop() {
      Some(v) => v
      None => break
    }
    ordered_names.push(name)
    match dependents.get(name) {
      Some(outgoing) =>
        for dependent_name, _ in outgoing {
          match indegree.get(dependent_name) {
            Some(deg) => {
              let next = deg - 1
              indegree[dependent_name] = next
              if next == 0 {
                canonical_sorted_insert(ready, dependent_name)
              }
            }
            None => ()
          }
        }
      None => ()
    }
  }
  if ordered_names.length() < defs.length() {
    let emitted : Map[String, Bool] = {}
    for name in ordered_names {
      emitted[name] = true
    }
    let unresolved : Array[String] = []
    for def in defs {
      if not(emitted.contains(def.0)) {
        unresolved.push(def.0)
        emitted[def.0] = true
      }
    }
    unresolved.sort_by(fn(a, b) { canonical_name_compare(a, b) })
    for name in unresolved {
      ordered_names.push(name)
    }
  }
  let sorted_defs : Array[Stmt] = []
  for name in ordered_names {
    match stmt_by_name.get(name) {
      Some(stmt) => sorted_defs.push(stmt)
      None => ()
    }
  }
  if sorted_defs.length() != defs.length() {
    return stmts
  }
  let out : Array[Stmt] = []
  let mut def_cursor = 0
  for stmt in stmts {
    match canonical_def_name(stmt) {
      Some(_) =>
        if def_cursor < sorted_defs.length() {
          out.push(sorted_defs[def_cursor])
          def_cursor += 1
        } else {
          out.push(stmt)
        }
      None => out.push(stmt)
    }
  }
  out
}

///|
/// Insert a name into a descending-sorted array maintaining order.
/// The array is sorted in descending canonical order so that pop() yields the smallest.
fn canonical_sorted_insert(arr : Array[String], name : String) -> Unit {
  let mut pos = arr.length()
  while pos > 0 && canonical_name_compare(arr[pos - 1], name) < 0 {
    pos -= 1
  }
  arr.insert(pos, name)
}

///|
fn canonical_name_is_member(name : String) -> Bool {
  let mut i = 0
  while i + 1 < name.length() {
    let c = name[i].to_int().unsafe_to_char()
    let next = name[i + 1].to_int().unsafe_to_char()
    if c == ':' && next == ':' {
      return true
    }
    i += 1
  }
  false
}

///|
fn canonical_name_compare(a : String, b : String) -> Int {
  let a_member = canonical_name_is_member(a)
  let b_member = canonical_name_is_member(b)
  if a_member && not(b_member) {
    1
  } else if not(a_member) && b_member {
    -1
  } else {
    String::compare(a, b)
  }
}
