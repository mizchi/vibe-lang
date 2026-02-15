///|
fn normalize_sort_stmts(
  stmts : Array[@vibe_core.Stmt],
) -> Array[@vibe_core.Stmt] {
  let use_stmts : Array[@vibe_core.Stmt] = []
  let type_stmts : Array[@vibe_core.Stmt] = []
  let trait_stmts : Array[@vibe_core.Stmt] = []
  let pure_fn_stmts : Array[@vibe_core.Stmt] = []
  let effectful_fn_stmts : Array[@vibe_core.Stmt] = []
  let other_stmts : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    match normalize_stmt_group(stmt) {
      NormalizeStmtGroup::Use => use_stmts.push(stmt)
      NormalizeStmtGroup::TypeDecl => type_stmts.push(stmt)
      NormalizeStmtGroup::TraitDecl => trait_stmts.push(stmt)
      NormalizeStmtGroup::PureFn => pure_fn_stmts.push(stmt)
      NormalizeStmtGroup::EffectfulFn => effectful_fn_stmts.push(stmt)
      NormalizeStmtGroup::Other => other_stmts.push(stmt)
    }
  }
  let pure_fn_sorted = normalize_sort_stmt_defs_topo_alpha(pure_fn_stmts)
  let effectful_fn_sorted = normalize_sort_stmt_defs_topo_alpha(
    effectful_fn_stmts,
  )
  let out : Array[@vibe_core.Stmt] = []
  for stmt in use_stmts {
    out.push(stmt)
  }
  for stmt in type_stmts {
    out.push(stmt)
  }
  for stmt in trait_stmts {
    out.push(stmt)
  }
  for stmt in pure_fn_sorted {
    out.push(stmt)
  }
  for stmt in effectful_fn_sorted {
    out.push(stmt)
  }
  for stmt in other_stmts {
    out.push(stmt)
  }
  out
}

///|
struct NormalizeStmtDef {
  name : String
  stmt : @vibe_core.Stmt
  refs : Map[String, Bool]
}

///|
fn normalize_sort_stmt_defs_topo_alpha(
  stmts : Array[@vibe_core.Stmt],
) -> Array[@vibe_core.Stmt] {
  let defs : Array[NormalizeStmtDef] = []
  for stmt in stmts {
    match normalize_stmt_def_name(stmt) {
      Some(name) =>
        defs.push({ name, stmt, refs: normalize_collect_stmt_refs(stmt) })
      None => ()
    }
  }
  if defs.length() <= 1 {
    return stmts
  }
  let names : Map[String, Bool] = {}
  for def in defs {
    if names.contains(def.name) {
      return stmts
    }
    names[def.name] = true
  }
  let indegree : Map[String, Int] = {}
  let dependents : Map[String, Map[String, Bool]] = {}
  let stmt_by_name : Map[String, @vibe_core.Stmt] = {}
  for def in defs {
    indegree[def.name] = 0
    dependents[def.name] = {}
    stmt_by_name[def.name] = def.stmt
  }
  for def in defs {
    let deps : Map[String, Bool] = {}
    for ref_name, _ in def.refs {
      if ref_name != def.name && names.contains(ref_name) {
        deps[ref_name] = true
      }
    }
    indegree[def.name] = deps.length()
    for dep_name, _ in deps {
      match dependents.get(dep_name) {
        Some(existing) => {
          let next = @vibe_core.clone_bool_map(existing)
          next[def.name] = true
          dependents[dep_name] = next
        }
        None => {
          let next : Map[String, Bool] = {}
          next[def.name] = true
          dependents[dep_name] = next
        }
      }
    }
  }
  let ready : Array[String] = []
  for name, deg in indegree {
    if deg == 0 {
      ready.push(name)
    }
  }
  let ordered_names : Array[String] = []
  while ready.length() > 0 {
    let name = match normalize_pop_smallest_name(ready) {
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
                ready.push(dependent_name)
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
      if not(emitted.contains(def.name)) {
        unresolved.push(def.name)
        emitted[def.name] = true
      }
    }
    unresolved.sort_by(fn(a, b) { normalize_name_compare(a, b) })
    for name in unresolved {
      ordered_names.push(name)
    }
  }
  let sorted_defs : Array[@vibe_core.Stmt] = []
  for name in ordered_names {
    match stmt_by_name.get(name) {
      Some(stmt) => sorted_defs.push(stmt)
      None => ()
    }
  }
  if sorted_defs.length() != defs.length() {
    return stmts
  }
  let out : Array[@vibe_core.Stmt] = []
  let mut def_cursor = 0
  for stmt in stmts {
    match normalize_stmt_def_name(stmt) {
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
fn normalize_stmt_def_name(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn normalize_collect_stmt_refs(stmt : @vibe_core.Stmt) -> Map[String, Bool] {
  let refs : Map[String, Bool] = {}
  let bound = @vibe_core.WalkerScope::new()
  match stmt {
    @vibe_core.Stmt::Let(rec~, name~, expr~, ..)
    | @vibe_core.Stmt::ExportLet(rec~, name~, expr~, ..) => {
      if rec {
        bound.bindings[name] = true
      }
      @vibe_core.walk_expr_refs(expr, bound, refs, normalize_add_ref_name)
    }
    @vibe_core.Stmt::LetMut(expr~, ..) =>
      @vibe_core.walk_expr_refs(expr, bound, refs, normalize_add_ref_name)
    _ => ()
  }
  refs
}

///|
fn normalize_add_ref_name(
  name : String,
  bound : @vibe_core.WalkerScope,
  refs : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  refs[name] = true
}

///|
fn normalize_pop_smallest_name(names : Array[String]) -> String? {
  if names.length() == 0 {
    return None
  }
  names.sort_by(fn(a, b) { normalize_name_compare(b, a) })
  names.pop()
}

///|
fn normalize_name_is_member(name : String) -> Bool {
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
fn normalize_name_compare(a : String, b : String) -> Int {
  let a_member = normalize_name_is_member(a)
  let b_member = normalize_name_is_member(b)
  if a_member && not(b_member) {
    1
  } else if not(a_member) && b_member {
    -1
  } else {
    String::compare(a, b)
  }
}

///|
fn normalize_stmt_group(stmt : @vibe_core.Stmt) -> NormalizeStmtGroup {
  match stmt {
    @vibe_core.Stmt::Import(..) | @vibe_core.Stmt::ReExport(..) =>
      NormalizeStmtGroup::Use
    @vibe_core.Stmt::TypeAlias(..)
    | @vibe_core.Stmt::ExportTypeAlias(..)
    | @vibe_core.Stmt::EnumDef(..)
    | @vibe_core.Stmt::ExportEnumDef(..)
    | @vibe_core.Stmt::StructDef(..)
    | @vibe_core.Stmt::ExportStructDef(..) => NormalizeStmtGroup::TypeDecl
    @vibe_core.Stmt::TraitDef(..) | @vibe_core.Stmt::TraitImpl(..) =>
      NormalizeStmtGroup::TraitDecl
    @vibe_core.Stmt::Let(expr~, ..) | @vibe_core.Stmt::ExportLet(expr~, ..) =>
      if normalize_expr_is_effectful_fn(expr) {
        NormalizeStmtGroup::EffectfulFn
      } else {
        NormalizeStmtGroup::PureFn
      }
    @vibe_core.Stmt::LetMut(..)
    | @vibe_core.Stmt::Assign(..)
    | @vibe_core.Stmt::IndexAssign(..)
    | @vibe_core.Stmt::LetPat(..)
    | @vibe_core.Stmt::LetPatElse(..)
    | @vibe_core.Stmt::Expr(..) => NormalizeStmtGroup::EffectfulFn
    @vibe_core.Stmt::Test(..)
    | @vibe_core.Stmt::Bench(..)
    | @vibe_core.Stmt::Export(..) => NormalizeStmtGroup::Other
  }
}

///|
fn normalize_expr_is_effectful_fn(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Fn(effects~, ..) => effects.length() > 0
    _ => false
  }
}
